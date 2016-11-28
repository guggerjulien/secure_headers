module SecureHeaders
  module ControllerExtension
    class << self
      def append_features(base)
        base.module_eval do
          extend ClassMethods
          include InstanceMethods
        end
      end
    end

    module ClassMethods
      attr_writer :secure_headers_options
      def secure_headers_options
        if @secure_headers_options
          @secure_headers_options
        elsif superclass.respond_to?(:secure_headers_options) # stop at application_controller
          superclass.secure_headers_options
        else
          {}
        end
      end

      def ensure_security_headers options = {}
        if RUBY_VERSION == "1.8.7"
          warn "[DEPRECATION] secure_headers ruby 1.8.7 support will dropped in the next release"
        end
        self.secure_headers_options = options
        hook = respond_to?(:before_action) ? :before_action : :before_filter
        ::SecureHeaders::ALL_FILTER_METHODS.each do |method|
          send(hook, method)
        end
      end
    end

    module InstanceMethods
      def set_security_headers(options = self.class.secure_headers_options)
        set_csp_header(request, options[:csp])
        set_hsts_header(options[:hsts])
        set_hpkp_header(options[:hpkp])
        set_x_frame_options_header(options[:x_frame_options])
        set_x_xss_protection_header(options[:x_xss_protection])
        set_x_content_type_options_header(options[:x_content_type_options])
        set_x_download_options_header(options[:x_download_options])
        set_x_permitted_cross_domain_policies_header(options[:x_permitted_cross_domain_policies])
      end

      # set_csp_header - uses the request accessor and SecureHeader::Configuration settings
      # set_csp_header(+Rack::Request+) - uses the parameter and and SecureHeader::Configuration settings
      # set_csp_header(+Hash+) - uses the request accessor and options from parameters
      # set_csp_header(+Rack::Request+, +Hash+)
      def set_csp_header(req = nil, config=nil)
        if req.is_a?(Hash) || req.is_a?(FalseClass)
          config = req
        end

        config = self.class.secure_headers_options[:csp] if config.nil?
        config = secure_header_options_for :csp, config

        return if config == false

        if config && config[:script_hash_middleware]
          ContentSecurityPolicy.add_to_env(request, self, config)
        else
          csp_header = ContentSecurityPolicy.new(config, :request => request, :controller => self)
          set_header(csp_header)
        end
      end


      def prep_script_hash
        if ::SecureHeaders::Configuration.script_hashes
          @script_hashes = ::SecureHeaders::Configuration.script_hashes.dup
          ActiveSupport::Notifications.subscribe("render_partial.action_view") do |event_name, start_at, end_at, id, payload|
            save_hash_for_later payload
          end

          ActiveSupport::Notifications.subscribe("render_template.action_view") do |event_name, start_at, end_at, id, payload|
            save_hash_for_later payload
          end
        end
      end

      def save_hash_for_later payload
        matching_hashes = @script_hashes[payload[:identifier].gsub(Rails.root.to_s + "/", "")] || []

        if payload[:layout]
          # We're assuming an html.erb layout for now. Will need to handle mustache too, just not sure of the best way to do this
          layout_hashes = @script_hashes[File.join("app", "views", payload[:layout]) + '.html.erb']

          matching_hashes << layout_hashes if layout_hashes
        end

        if matching_hashes.any?
          request.env[HASHES_ENV_KEY] = ((request.env[HASHES_ENV_KEY] || []) << matching_hashes).flatten
        end
      end

      def set_x_frame_options_header(options=self.class.secure_headers_options[:x_frame_options])
        set_a_header(:x_frame_options, XFrameOptions, options)
      end

      def set_x_content_type_options_header(options=self.class.secure_headers_options[:x_content_type_options])
        set_a_header(:x_content_type_options, XContentTypeOptions, options)
      end

      def set_x_xss_protection_header(options=self.class.secure_headers_options[:x_xss_protection])
        set_a_header(:x_xss_protection, XXssProtection, options)
      end

      def set_hsts_header(options=self.class.secure_headers_options[:hsts])
        return unless request.ssl?
        set_a_header(:hsts, StrictTransportSecurity, options)
      end

      def set_hpkp_header(options=self.class.secure_headers_options[:hpkp])
        return unless request.ssl?
        config = secure_header_options_for :hpkp, options

        return if config == false || config.nil?

        hpkp_header = PublicKeyPins.new(config)
        set_header(hpkp_header)
      end

      def set_x_download_options_header(options=self.class.secure_headers_options[:x_download_options])
        set_a_header(:x_download_options, XDownloadOptions, options)
      end

      def set_x_permitted_cross_domain_policies_header(options=self.class.secure_headers_options[:x_permitted_cross_domain_policies])
        set_a_header(:x_permitted_cross_domain_policies, XPermittedCrossDomainPolicies, options)
      end

      private

      # we can't use ||= because I'm overloading false => disable, nil => default
      # both of which trigger the conditional assignment
      def secure_header_options_for(type, options)
        options.nil? ? ::SecureHeaders::Configuration.send(type) : options
      end

      def set_a_header(name, klass, options=nil)
        options = secure_header_options_for(name, options)
        return if options == false
        set_header(SecureHeaders::get_a_header(klass, options))
      end

      def set_header(name_or_header, value=nil)
        if name_or_header.is_a?(Header)
          header = name_or_header
          response.headers[header.name] = header.value
        else
          response.headers[name_or_header] = value
        end
      end
    end
  end
end