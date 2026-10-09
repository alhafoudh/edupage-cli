module Edupage
  class Credentials
    # Base for the operating system's own credential stores. They hold only the
    # password, keyed by service and username; username and school come from ENV,
    # flags or config.
    #
    # Subclasses implement the private #read, #write and #remove. Everything that has to
    # hold for every store - no lookups where the store does not exist, no empty
    # passwords, a read-back after every write - lives here.
    class SystemAdapter < Adapter
      SERVICE = "edupage-cli".freeze

      attr_reader :service

      def initialize(service: SERVICE)
        super()
        @service = service
      end

      def writable? = true

      def password(username: nil, **)
        return nil if username.nil? || username.empty?
        return nil unless self.class.available?

        value = read(username)
        value && !value.empty? ? value : nil
      end

      def store(username:, password:)
        ensure_available!
        secret = password.to_s
        raise ArgumentError, "password must not be empty" if secret.empty?

        write(username, secret)

        # Stores can report success and still persist something else (see
        # MacosKeychain), so a write only counts once it reads back intact.
        unless password(username: username) == secret
          raise Error, "#{display_name} reported success but stored a different password"
        end

        true
      end

      # True when something was stored and is now gone.
      def delete(username:)
        ensure_available!
        remove(username)
      end

      def stored?(username:)
        !password(username: username).nil?
      end

      private

      def read(_username)
        raise NotImplementedError, "#{self.class.name}#read is not implemented"
      end

      def write(_username, _secret)
        raise NotImplementedError, "#{self.class.name}#write is not implemented"
      end

      def remove(_username)
        raise NotImplementedError, "#{self.class.name}#remove is not implemented"
      end

      def ensure_available!
        return if self.class.available?

        raise UnsupportedPlatformError,
              "The #{display_name} is not available on #{RUBY_PLATFORM}. Use EDUPAGE_PASSWORD instead."
      end
    end
  end
end
