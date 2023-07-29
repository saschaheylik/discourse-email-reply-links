# name: email-reply-links
# about: Adds clickable mailto links at the end of a notification email to allow you to like, watch, track or mute a post or topic.
# version: 0.0.1
# authors: Sascha Heylik
# url: https://github.com/saschaheylik/discourse-email-reply-links

module EmailReplyLinks
  PLUGIN_NAME = "email-reply-links"

  module MessageBuilderExtension
    def html_part
      return unless html_override = @opts[:html_override]

      unsubscribe_instructions =
        if (instructions_str = @template_args[:unsubscribe_instructions]).present?
          # Keep the <p> open, so we can add the reply links inside it before closing it
          PrettyText.cook(instructions_str, sanitize: false).gsub("</p>","") + "<br/>"
        else
          "<p>"
        end + reply_links + "</p>"

      html_override.gsub!("%{unsubscribe_instructions}", unsubscribe_instructions.html_safe)

      if @template_args[:header_instructions].present?
        header_instructions =
          PrettyText.cook(@template_args[:header_instructions], sanitize: false).html_safe
        html_override.gsub!("%{header_instructions}", header_instructions)
      else
        html_override.gsub!("%{header_instructions}", "")
      end

      if @template_args[:respond_instructions].present?
        respond_instructions =
          PrettyText.cook(@template_args[:respond_instructions], sanitize: false).html_safe
        html_override.gsub!("%{respond_instructions}", respond_instructions)
      else
        html_override.gsub!("%{respond_instructions}", "")
      end

      html =
        UserNotificationRenderer.render(
          template: "layouts/email_template",
          format: :html,
          locals: {
            html_body: html_override.html_safe,
          },
        )

      Mail::Part.new do
        content_type "text/html; charset=UTF-8"
        body html
      end
    end

    def body
      body = nil

      if @opts[:template]
        body = I18n.t("#{@opts[:template]}.text_body_template", template_args).dup
      else
        body = @opts[:body].dup
      end

      if @template_args[:unsubscribe_instructions].present?
        body << "\n"
        body << @template_args[:unsubscribe_instructions]
      end

      body
    end

    protected

    def reply_links
      ["like", "watch", "track", "mute"].map do |action|
        thing = (action == "like") ? "post" : "topic"
        "To #{action} the #{thing}, <a href=\"#{reply_mail_to action}\">click here</a>."
      end.join "<br/>"
    end

    def reply_mail_to action
      reply_email = SiteSetting.reply_by_email_address
      encoded_subject = ERB::Util.url_encode subject

      "mailto:#{reply_email}?subject=#{encoded_subject}&body=#{action}"
    end
  end

 module SenderExtension
    def send
      bypass_disable = BYPASS_DISABLE_TYPES.include?(@email_type.to_s)

      return if SiteSetting.disable_emails == "yes" && !bypass_disable

      return if ActionMailer::Base::NullMail === @message
      if ActionMailer::Base::NullMail ===
           (
             begin
               @message.message
             rescue StandardError
               nil
             end
           )
        return
      end

      return skip(SkippedEmailLog.reason_types[:sender_message_blank]) if @message.blank?
      return skip(SkippedEmailLog.reason_types[:sender_message_to_blank]) if @message.to.blank?

      if SiteSetting.disable_emails == "non-staff" && !bypass_disable
        return unless find_user&.staff?
      end

      if to_address.end_with?(".invalid")
        return skip(SkippedEmailLog.reason_types[:sender_message_to_invalid])
      end

      if @message.text_part
        if @message.text_part.body.to_s.blank?
          return skip(SkippedEmailLog.reason_types[:sender_text_part_body_blank])
        end
      else
        return skip(SkippedEmailLog.reason_types[:sender_body_blank]) if @message.body.to_s.blank?
      end

      @message.charset = "UTF-8"

      opts = {}

      renderer = Email::Renderer.new(@message, opts)

      if @message.html_part
        @message.html_part.body = renderer.html
      else
        @message.html_part =
          Mail::Part.new do
            content_type "text/html; charset=UTF-8"
            body renderer.html
          end
      end

      # Fix relative (ie upload) HTML links in markdown which do not work well in plain text emails.
      # These are the links we add when a user uploads a file or image.
      # Ideally we would parse general markdown into plain text, but that is almost an intractable problem.
      url_prefix = Discourse.base_url
      @message.parts[0].body =
        @message.parts[0].body.to_s.gsub(
          %r{<a class="attachment" href="(/uploads/default/[^"]+)">([^<]*)</a>},
          '[\2|attachment](' + url_prefix + '\1)',
        )
      @message.parts[0].body =
        @message.parts[0].body.to_s.gsub(
          %r{<img src="(/uploads/default/[^"]+)"([^>]*)>},
          "![](" + url_prefix + '\1)',
        )

      @message.text_part.content_type = "text/plain; charset=UTF-8"
      user_id = @user&.id

      # Set up the email log
      email_log = EmailLog.new(email_type: @email_type, to_address: to_address, user_id: user_id)

      if cc_addresses.any?
        email_log.cc_addresses = cc_addresses.join(";")
        email_log.cc_user_ids = User.with_email(cc_addresses).pluck(:id)
      end

      email_log.bcc_addresses = bcc_addresses.join(";") if bcc_addresses.any?

      host = Email::Sender.host_for(Discourse.base_url)

      post_id = header_value("X-Discourse-Post-Id")
      topic_id = header_value("X-Discourse-Topic-Id")
      reply_key = get_reply_key(post_id, user_id)
      from_address = @message.from&.first
      smtp_group_id =
        (
          if from_address.blank?
            nil
          else
            Group.where(email_username: from_address, smtp_enabled: true).pick(:id)
          end
        )

      # always set a default Message ID from the host
      @message.header["Message-ID"] = Email::MessageIdService.generate_default

      if topic_id.present? && post_id.present?
        post = Post.find_by(id: post_id, topic_id: topic_id)

        # guards against deleted posts and topics
        return skip(SkippedEmailLog.reason_types[:sender_post_deleted]) if post.blank?

        topic = post.topic
        return skip(SkippedEmailLog.reason_types[:sender_topic_deleted]) if topic.blank?

        add_attachments(post)
        add_identification_field_headers(topic, post)

        # See https://www.ietf.org/rfc/rfc2919.txt for the List-ID
        # specification.
        if topic&.category && !topic.category.uncategorized?
          list_id =
            "#{SiteSetting.title} | #{topic.category.name} <#{topic.category.name.downcase.tr(" ", "-")}.#{host}>"

          # subcategory case
          if !topic.category.parent_category_id.nil?
            parent_category_name = Category.find_by(id: topic.category.parent_category_id).name
            list_id =
              "#{SiteSetting.title} | #{parent_category_name} #{topic.category.name} <#{topic.category.name.downcase.tr(" ", "-")}.#{parent_category_name.downcase.tr(" ", "-")}.#{host}>"
          end
        else
          list_id = "#{SiteSetting.title} <#{host}>"
        end

        # When we are emailing people from a group inbox, we are having a PM
        # conversation with them, as a support account would. In this case
        # mailing list headers do not make sense. It is not like a forum topic
        # where you may have tens or hundreds of participants -- it is a
        # conversation between the group and a small handful of people
        # directly contacting the group, often just one person.
        if !smtp_group_id
          # https://www.ietf.org/rfc/rfc3834.txt
          @message.header["Precedence"] = "list"
          @message.header["List-ID"] = list_id

          if topic
            if SiteSetting.private_email?
              @message.header["List-Archive"] = "#{Discourse.base_url}#{topic.slugless_url}"
            else
              @message.header["List-Archive"] = topic.url
            end
          end
        end
      end

      if Email::Sender.bounceable_reply_address?
        email_log.bounce_key = SecureRandom.hex

        # WARNING: RFC claims you can not set the Return Path header, this is 100% correct
        # however Rails has special handling for this header and ends up using this value
        # as the Envelope From address so stuff works as expected
        @message.header[:return_path] = Email::Sender.bounce_address(email_log.bounce_key)
      end

      email_log.post_id = post_id if post_id.present?
      email_log.topic_id = topic_id if topic_id.present?

      if reply_key.present?
        insert_reply_key @message, reply_key

        @message.header["Reply-To"] = header_value("Reply-To").gsub!("%{reply_key}", reply_key)
        @message.header[Email::MessageBuilder::ALLOW_REPLY_BY_EMAIL_HEADER] = nil
      end

      Email::MessageBuilder
        .custom_headers(SiteSetting.email_custom_headers)
        .each do |key, _|
          # Any custom headers added via MessageBuilder that are doubled up here
          # with values that we determine should be set to the last value, which is
          # the one we determined. Our header values should always override the email_custom_headers.
          #
          # While it is valid via RFC5322 to have more than one value for certain headers,
          # we just want to keep it to one, especially in cases where the custom value
          # would conflict with our own.
          #
          # See https://datatracker.ietf.org/doc/html/rfc5322#section-3.6 and
          # https://github.com/mikel/mail/blob/8ef377d6a2ca78aa5bd7f739813f5a0648482087/lib/mail/header.rb#L109-L132
          custom_header = @message.header[key]
          if custom_header.is_a?(Array)
            our_value = custom_header.last.value

            # Must be set to nil first otherwise another value is just added
            # to the array of values for the header.
            @message.header[key] = nil
            @message.header[key] = our_value
          end

          value = header_value(key)

          # Remove Auto-Submitted header for group private message emails, it does
          # not make sense there and may hurt deliverability.
          #
          # From https://www.iana.org/assignments/auto-submitted-keywords/auto-submitted-keywords.xhtml:
          #
          # > Indicates that a message was generated by an automatic process, and is not a direct response to another message.
          @message.header[key] = nil if key.downcase == "auto-submitted" && smtp_group_id

          # Replace reply_key in custom headers or remove
          if value&.include?("%{reply_key}")
            # Delete old header first or else the same header will be added twice
            @message.header[key] = nil
            @message.header[key] = value.gsub!("%{reply_key}", reply_key) if reply_key.present?
          end
        end

      # pass the original message_id when using mailjet/mandrill/sparkpost
      case ActionMailer::Base.smtp_settings[:address]
      when /\.mailjet\.com/
        @message.header["X-MJ-CustomID"] = @message.message_id
      when "smtp.mandrillapp.com"
        merge_json_x_header("X-MC-Metadata", message_id: @message.message_id)
      when "smtp.sparkpostmail.com"
        merge_json_x_header("X-MSYS-API", metadata: { message_id: @message.message_id })
      end

      # Parse the HTML again so we can make any final changes before
      # sending
      style = Email::Styles.new(@message.html_part.body.to_s)

      # Suppress images from short emails
      if SiteSetting.strip_images_from_short_emails &&
           @message.html_part.body.to_s.bytesize <= SiteSetting.short_email_length &&
           @message.html_part.body =~ /<img[^>]+>/
        style.strip_avatars_and_emojis
      end

      # Embeds any of the secure images that have been attached inline,
      # removing the redaction notice.
      if SiteSetting.secure_uploads_allow_embed_images_in_emails
        style.inline_secure_images(@message.attachments, @message_attachments_index)
      end

      @message.html_part.body = style.to_s

      email_log.message_id = @message.message_id

      # Log when a message is being sent from a group SMTP address, so we
      # can debug deliverability issues.
      if smtp_group_id
        email_log.smtp_group_id = smtp_group_id

        # Store contents of all outgoing emails using group SMTP
        # for greater visibility and debugging. If the size of this
        # gets out of hand, we should look into a group-level setting
        # to enable this; size should be kept in check by regular purging
        # of EmailLog though.
        email_log.raw = Email::Cleaner.new(@message).execute
      end

      DiscourseEvent.trigger(:before_email_send, @message, @email_type)

      begin
        message_response = @message.deliver!

        # TestMailer from the Mail gem does not return a real response, it
        # returns an array containing @message, so we have to have this workaround.
        if message_response.kind_of?(Net::SMTP::Response)
          email_log.smtp_transaction_response = message_response.message&.chomp
        end
      rescue *SMTP_CLIENT_ERRORS => e
        return skip(SkippedEmailLog.reason_types[:custom], custom_reason: e.message)
      end

      DiscourseEvent.trigger(:after_email_send, @message, @email_type)

      email_log.save!
      email_log
    end


    private

    def insert_reply_key message, reply_key
      body = message.message.html_part.body.to_s
      message.message.html_part.body = body.gsub("%{reply_key}", reply_key)
    end
  end
end

after_initialize do
  reloadable_patch do |plugin|
    Email::MessageBuilder.prepend EmailReplyLinks::MessageBuilderExtension
    Email::Sender.prepend EmailReplyLinks::SenderExtension
  end
end
