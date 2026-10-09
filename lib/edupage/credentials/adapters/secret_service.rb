require "open3"

module Edupage
  class Credentials
    module Adapters
      # The freedesktop Secret Service (GNOME Keyring, KWallet), driven through
      # `secret-tool` from libsecret.
      #
      # Entries carry the attributes service=<service> and account=<username>. The
      # password goes in on stdin, never in argv; with a pipe rather than a terminal on
      # stdin, `secret-tool store` reads it verbatim instead of prompting.
      #
      # Without a D-Bus session (a plain SSH login, a container) lookups fail; that reads
      # as "nothing stored" so ENV-less runs still get the usual missing-password hint.
      class SecretService < SystemAdapter
        class << self
          def available?
            RUBY_PLATFORM.include?("linux") && !executable.nil?
          end

          def display_name = "Secret Service (libsecret)"

          def executable
            ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
               .map { |dir| File.join(dir, "secret-tool") }
               .find { |path| File.executable?(path) }
          end
        end

        def source_for(_field) = "secret service"

        private

        def attributes(username) = ["service", service, "account", username]

        def read(username)
          # Prints the secret as-is, without a trailing newline when stdout is a pipe.
          out, _err, status = Open3.capture3(self.class.executable, "lookup", *attributes(username))
          status.success? ? out.force_encoding(Encoding::UTF_8) : nil
        end

        def write(username, secret)
          _out, err, status = Open3.capture3(
            self.class.executable, "store", "--label", "#{service} (#{username})", *attributes(username),
            stdin_data: secret
          )
          raise Error, "Failed to store password in #{display_name}: #{err.strip}" unless status.success?
        end

        # `secret-tool clear` exits 0 whether or not anything matched, so whether there
        # was something to remove is checked first.
        def remove(username)
          existed = stored?(username: username)
          Open3.capture3(self.class.executable, "clear", *attributes(username))
          existed
        end
      end
    end
  end
end
