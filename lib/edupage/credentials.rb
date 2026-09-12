module Edupage
  # Resolves username / password / school from an ordered list of providers.
  #
  # ENV always wins over the keychain. That ordering is deliberate but surprising
  # (an `edupage login` looks like a no-op while EDUPAGE_PASSWORD is exported), so
  # #password_source is reported by `edupage auth status`.
  class Credentials
    Resolved = Struct.new(:value, :source, keyword_init: true)

    attr_reader :username_override, :school_override

    def initialize(username: nil, school: nil, providers: nil, config: Edupage.config)
      @username_override = username
      @school_override = school
      @config = config
      @providers = providers || default_providers
    end

    def default_providers
      [Credentials::Env.new].tap do |list|
        list << Credentials::Keychain.new if Credentials::Keychain.available?
      end
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

    # True when ENV supplies the password while a lower-priority provider also holds
    # one, i.e. a stored password is being silently shadowed. Providers are compared by
    # the source they report rather than by class, so any provider chain works.
    def password_shadowed?
      winning = resolved_password.source
      return false unless winning&.start_with?("ENV:")

      user = resolved_username.value
      @providers.any? do |provider|
        next false if provider.source_for(:password) == winning

        value = provider.password(username: user)
        value && !value.empty?
      end
    end

    def to_h
      { username: resolved_username.value, school: resolved_school.value }
    end

    # Never let a password reach a log line, a backtrace or `p`.
    def inspect = "#<Edupage::Credentials username=#{resolved_username.value.inspect}>"
    alias to_s inspect

    private

    def resolved_username
      @resolved_username ||= begin
        from_providers(:username) ||
          wrap(@username_override, "--username") ||
          wrap(@config.default_username, "config") ||
          Resolved.new(value: nil, source: nil)
      end
    end

    def resolved_password
      @resolved_password ||=
        from_providers(:password, username: resolved_username.value) ||
        Resolved.new(value: nil, source: nil)
    end

    def resolved_school
      @resolved_school ||= begin
        from_providers(:school) ||
          wrap(@school_override, "--school") ||
          wrap(@config.default_school, "config") ||
          Resolved.new(value: nil, source: nil)
      end
    end

    # An override beats a lower-priority provider but never beats ENV, so overrides are
    # only consulted after the provider chain comes up empty.
    def from_providers(field, **args)
      @providers.each do |provider|
        value = provider.public_send(field, **args)
        return Resolved.new(value: value, source: provider.source_for(field)) if value && !value.empty?
      end
      nil
    end

    def wrap(value, source)
      return nil if value.nil? || value.to_s.empty?

      Resolved.new(value: value.to_s, source: source)
    end

    def missing_password_message
      if Credentials::Keychain.available?
        "No password. Run `edupage login`, or set EDUPAGE_PASSWORD."
      else
        "No password and the macOS keychain is unavailable on this platform. Set EDUPAGE_PASSWORD."
      end
    end
  end
end
