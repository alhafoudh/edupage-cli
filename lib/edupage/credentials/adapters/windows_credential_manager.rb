module Edupage
  class Credentials
    module Adapters
      # Windows Credential Manager, called through advapi32 with Fiddle.
      #
      # Windows ships no command that reads a stored password back (cmdkey only writes
      # one), so this talks to the Cred* API directly: no subprocess, and the password
      # never appears in argv.
      #
      # Entries are generic credentials named "<service>:<username>". The blob holds the
      # password as UTF-8 bytes; Credential Manager treats it as opaque.
      class WindowsCredentialManager < SystemAdapter
        CRED_TYPE_GENERIC = 1
        CRED_PERSIST_LOCAL_MACHINE = 2

        class << self
          def available? = Gem.win_platform?
          def display_name = "Windows Credential Manager"

          # Built on first use, so Fiddle is never loaded on other platforms or when ENV
          # already supplied the password.
          def api
            @api ||= begin
              require "fiddle/import"

              Module.new do
                extend Fiddle::Importer

                dlload "advapi32.dll"
                extern "int CredReadW(void*, uint32_t, uint32_t, void*)"
                extern "int CredWriteW(void*, uint32_t)"
                extern "int CredDeleteW(void*, uint32_t, uint32_t)"
                extern "void CredFree(void*)"
              end
            end
          end

          # CREDENTIALW. FILETIME is two DWORDs; Fiddle works out the padding before
          # each pointer, so the layout matches on both x64 and arm64.
          def credential
            @credential ||= api.struct([
                                         "uint32_t flags",
                                         "uint32_t type",
                                         "void* target_name",
                                         "void* comment",
                                         "uint32_t last_written_low",
                                         "uint32_t last_written_high",
                                         "uint32_t blob_size",
                                         "void* blob",
                                         "uint32_t persist",
                                         "uint32_t attribute_count",
                                         "void* attributes",
                                         "void* target_alias",
                                         "void* user_name"
                                       ])
          end
        end

        def source_for(_field) = "credential manager"

        def target_name(username) = "#{service}:#{username}"

        private

        # Each entry point fetches the API first: that is what requires Fiddle, so it has
        # to happen before any other Fiddle constant is touched.
        def read(username)
          api = self.class.api
          slot = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
          return nil if api.CredReadW(wide(target_name(username)), CRED_TYPE_GENERIC, 0, slot).zero?

          address = slot.ptr.to_i
          begin
            entry = self.class.credential.new(address)
            Fiddle::Pointer.new(entry.blob.to_i)[0, entry.blob_size].force_encoding(Encoding::UTF_8)
          ensure
            api.CredFree(address)
          end
        end

        def write(username, secret)
          api = self.class.api
          # Locals keep the buffers alive until CredWriteW has copied them.
          target = wide(target_name(username))
          user = wide(username)
          blob = secret.b

          entry = self.class.credential.malloc(Fiddle::RUBY_FREE)
          entry.flags = 0
          entry.type = CRED_TYPE_GENERIC
          entry.target_name = target.to_i
          entry.comment = 0
          entry.last_written_low = 0
          entry.last_written_high = 0
          entry.blob_size = blob.bytesize
          entry.blob = Fiddle::Pointer[blob].to_i
          entry.persist = CRED_PERSIST_LOCAL_MACHINE
          entry.attribute_count = 0
          entry.attributes = 0
          entry.target_alias = 0
          entry.user_name = user.to_i

          return unless api.CredWriteW(entry.to_ptr, 0).zero?

          raise Error, "Failed to store password in #{display_name} (Win32 error #{Fiddle.win32_last_error})"
        end

        # Whether there is anything to remove is checked up front rather than read off
        # ERROR_NOT_FOUND (1168): on Windows arm64 with Ruby 4.0, Fiddle reports the last error
        # as 0 after a failed CredDeleteW.
        def remove(username)
          return false unless stored?(username: username)

          api = self.class.api
          return true unless api.CredDeleteW(wide(target_name(username)), CRED_TYPE_GENERIC, 0).zero?

          raise Error, "Failed to remove password from #{display_name} (Win32 error #{Fiddle.win32_last_error.inspect})"
        end

        # A NUL-terminated UTF-16LE copy of +str+, as the W functions expect.
        def wide(str)
          Fiddle::Pointer["#{str}\0".encode(Encoding::UTF_16LE)]
        end
      end
    end
  end
end
