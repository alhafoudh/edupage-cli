module Edupage
  # Resolves username / password / school from credential adapters.
  #
  # ENV wins over everything. When it supplies a value nothing else is consulted, and the
  # operating system's credential store in particular is never touched: no keychain
  # prompt, no subprocess, no FFI load. That store is looked up lazily and only as the
  # last resort for the password. Username and school fall back to --username/--school
  # and then config instead.
  class Credentials
    Resolved = Struct.new(:value, :source, keyword_init: true)

    # Tried in order; the first one available on this machine is the system store.
    SYSTEM_ADAPTERS = [
      Adapters::MacosKeychain,
      Adapters::WindowsCredentialManager,
      Adapters::SecretService
    ].freeze

    class << self
      # The credential store of this operating system, or nil when there is none.
      def system_adapter
        SYSTEM_ADAPTERS.find(&:available?)&.new
      end
    end

    attr_reader :username_override, :school_override

    # +system+ is a callable rather than an adapter so that building Credentials never
    # touches the store; it is called at most once, and only when ENV has no password.
    def initialize(username: nil, school: nil, env: Adapters::Env.new,
                   system: -> { Credentials.system_adapter }, config: Edupage.config)
      @username_override = username
      @school_override = school
      @config = config
      @env = env
      @system = system
    end

    def username
      resolved_username.value or
        raise MissingCredentialsError,
              "No username. Pass --username, set EDUPAGE_USERNAME, or set default_username in #{@config.path}."
    end

    def password
      resolved_password.value or
        raise MissingCredentialsError, missing_password_message
    end

    def school
      resolved_school.value
    end

    def username_source = resolved_username.source
    def password_source = resolved_password.source
    def school_source   = resolved_school.source

    # True when ENV supplies the password, i.e. the system store is not consulted.
    def password_from_env?
      !from(@env, :password).nil?
    end

    def to_h
      { username: resolved_username.value, school: resolved_school.value }
    end

    # Never let a password reach a log line, a backtrace or `p`.
    def inspect = "#<Edupage::Credentials username=#{resolved_username.value.inspect}>"
    alias to_s inspect

    private

    def resolved_username
      @resolved_username ||=
        from(@env, :username) ||
        wrap(@username_override, "--username") ||
        wrap(@config.default_username, "config") ||
        Resolved.new(value: nil, source: nil)
    end

    def resolved_password
      @resolved_password ||=
        from(@env, :password) ||
        from(system_adapter, :password, username: resolved_username.value) ||
        Resolved.new(value: nil, source: nil)
    end

    def resolved_school
      @resolved_school ||=
        from(@env, :school) ||
        wrap(@school_override, "--school") ||
        wrap(@config.default_school, "config") ||
        Resolved.new(value: nil, source: nil)
    end

    def system_adapter
      return @system_adapter if defined?(@system_adapter)

      @system_adapter = @system.call
    end

    def from(adapter, field, **args)
      return nil unless adapter

      value = adapter.public_send(field, **args)
      Resolved.new(value: value, source: adapter.source_for(field)) if value && !value.empty?
    end

    def wrap(value, source)
      return nil if value.nil? || value.to_s.empty?

      Resolved.new(value: value.to_s, source: source)
    end

    def missing_password_message
      if (adapter = system_adapter)
        "No password. Run `edupage login` to store it in the #{adapter.display_name}, or set EDUPAGE_PASSWORD."
      else
        "No password and no OS credential store is available on #{RUBY_PLATFORM}. Set EDUPAGE_PASSWORD."
      end
    end
  end
end
