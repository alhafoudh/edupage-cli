require "open3"
require "rbconfig"

module Edupage
  class Credentials
    module Adapters
      # The macOS keychain, driven through /usr/bin/security.
      #
      # The password is never passed in argv (where `ps` would expose it). `security`
      # reads it from stdin instead, prompting twice, so writes send the value twice.
      #
      # `security add-generic-password` exits 0 even when the two reads disagree, storing
      # an empty password - which is what the read-back in SystemAdapter#store catches.
      class MacosKeychain < SystemAdapter
        SECURITY = "/usr/bin/security".freeze
        # Runs a command in a new session, without a controlling terminal. macOS ships no
        # setsid(1), so Ruby itself does the setsid before exec.
        DETACH = [RbConfig.ruby, "-e", "Process.setsid; exec(*ARGV)"].freeze

        class << self
          def available?
            RUBY_PLATFORM.include?("darwin") && File.executable?(SECURITY)
          end

          def display_name = "macOS keychain"
        end

        def source_for(_field) = "keychain"

        private

        def read(username)
          # -g, not -w: for non-ASCII passwords `-w` prints bare hex, which is
          # indistinguishable from an ASCII password that happens to look like hex
          # ("deadbeef"). -g prefixes the hex form with 0x, so it can be told apart.
          _out, err, status = Open3.capture3(
            SECURITY, "find-generic-password", "-s", service, "-a", username, "-g"
          )
          return nil unless status.success?

          parse_password(err)
        end

        def write(username, secret)
          # -w last with no value: `security` prompts on stdin rather than taking argv.
          # It prefers /dev/tty over stdin when it has a terminal, so it runs detached
          # from ours; otherwise it would ignore stdin_data and prompt the user instead.
          _out, err, status = Open3.capture3(
            *DETACH, SECURITY, "add-generic-password", "-s", service, "-a", username,
            "-l", "#{service} (#{username})", "-U", "-w",
            stdin_data: "#{secret}\n#{secret}\n"
          )
          raise Error, "Failed to store password in keychain: #{err.strip}" unless status.success?
        end

        def remove(username)
          _out, _err, status = Open3.capture3(
            SECURITY, "delete-generic-password", "-s", service, "-a", username
          )
          status.success?
        end

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
      end
    end
  end
end
