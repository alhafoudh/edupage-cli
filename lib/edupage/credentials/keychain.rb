require "open3"

module Edupage
  class Credentials
    # Secondary provider: the macOS keychain, driven through /usr/bin/security.
    #
    # The password is never passed in argv (where `ps` would expose it). `security`
    # reads it from stdin instead, prompting twice, so writes send the value twice.
    #
    # `security add-generic-password` exits 0 even when the two reads disagree, storing
    # an empty password - so #store always reads the value back before reporting success.
    class Keychain
      SERVICE = "edupage-cli".freeze
      SECURITY = "/usr/bin/security".freeze

      class << self
        def available?
          RUBY_PLATFORM.include?("darwin") && File.executable?(SECURITY)
        end
      end

      def initialize(service: SERVICE)
        @service = service
      end

      # Only the password lives in the keychain; the other fields come from ENV or config.
      def username(**) = nil
      def school(**) = nil

      def password(username: nil, **)
        return nil if username.nil? || username.empty?
        return nil unless self.class.available?

        # -g, not -w: for non-ASCII passwords `-w` prints bare hex, which is
        # indistinguishable from an ASCII password that happens to look like hex
        # ("deadbeef"). -g prefixes the hex form with 0x, so it can be told apart.
        _out, err, status = Open3.capture3(
          SECURITY, "find-generic-password", "-s", @service, "-a", username, "-g"
        )
        return nil unless status.success?

        value = parse_password(err)
        value && !value.empty? ? value : nil
      end

      def store(username:, password:)
        ensure_available!
        secret = password.to_s
        raise ArgumentError, "password must not be empty" if secret.empty?

        # -w last with no value: `security` prompts on stdin rather than taking argv.
        _out, err, status = Open3.capture3(
          SECURITY, "add-generic-password", "-s", @service, "-a", username,
          "-l", "#{@service} (#{username})", "-U", "-w",
          stdin_data: "#{secret}\n#{secret}\n"
        )
        raise Error, "Failed to store password in keychain: #{err.strip}" unless status.success?

        # Guard against the silent-empty-write path described above.
        unless password(username: username) == secret
          raise Error, "Keychain reported success but stored a different password"
        end

        true
      end

      def delete(username:)
        ensure_available!

        _out, _err, status = Open3.capture3(
          SECURITY, "delete-generic-password", "-s", @service, "-a", username
        )
        status.success?
      end

      def stored?(username:)
        !password(username: username).nil?
      end

      def source_for(_field) = "keychain"

      private

      # `security -g` writes one of these to stderr:
      #   password: "plain-ascii"
      #   password: 0x73336372  "s3cr3t-\303\241"
      # The hex form is exact bytes, so it is preferred whenever present.
      def parse_password(stderr)
        line = stderr.lines.find { |l| l.start_with?("password:") }
        return nil unless line

        if (hex = line[/password: 0x([0-9A-Fa-f]+)/, 1])
          [hex].pack("H*").force_encoding(Encoding::UTF_8)
        elsif (quoted = line[/password: "(.*)"\s*\z/m, 1])
          unescape(quoted)
        end
      end

      def unescape(str)
        str.gsub(/\\(\d{3}|.)/) do
          esc = Regexp.last_match(1)
          esc.match?(/\A\d{3}\z/) ? esc.to_i(8).chr : esc
        end.force_encoding(Encoding::UTF_8)
      end

      def ensure_available!
        return if self.class.available?

        raise UnsupportedPlatformError,
              "The macOS keychain is not available on #{RUBY_PLATFORM}. Use EDUPAGE_PASSWORD instead."
      end
    end
  end
end
