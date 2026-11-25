require "base64"
require "digest"
require "openssl"
require "securerandom"

module Edupage
  module Server
    module Public
      # Token generation and the envelope encryption behind grants.
      #
      # A grant's Edupage login is sealed under a random data key. That key is only ever
      # stored wrapped, under keys derived from token secrets the server keeps nothing
      # but a hash of, so the database on its own cannot be decrypted.
      module Crypto
        class DecryptError < StandardError; end

        PREFIXES = %w[ec ea er].freeze
        TOKEN_PATTERN = /\A(#{PREFIXES.join("|")})_([0-9a-f]{32})\.([A-Za-z0-9_-]{43})\z/
        HKDF_INFO = "edupage-public-wrap-v1".freeze
        IV_BYTES = 12
        TAG_BYTES = 16

        module_function

        # Returns [id, secret, "prefix_id.secret"].
        def generate_token(prefix)
          raise ArgumentError, "unknown token prefix #{prefix.inspect}" unless PREFIXES.include?(prefix)

          id = SecureRandom.hex(16)
          secret = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
          [id, secret, "#{prefix}_#{id}.#{secret}"]
        end

        # Header values arrive as binary strings from Puma; SQLite would bind those as
        # BLOBs, which never equal the TEXT ids, so the parts come back as UTF-8.
        def parse_token(string)
          match = TOKEN_PATTERN.match(string.to_s)
          match&.captures&.map { |part| part.dup.force_encoding(Encoding::UTF_8) }
        end

        def digest(secret) = Digest::SHA256.hexdigest(secret.to_s)

        def secure_equal?(left, right)
          return false unless left.bytesize == right.bytesize

          OpenSSL.fixed_length_secure_compare(left, right)
        end

        def random_key = SecureRandom.random_bytes(32)

        def derive_key(pepper:, secret:)
          OpenSSL::KDF.hkdf(secret.to_s, salt: pepper, info: HKDF_INFO, length: 32, hash: "SHA256")
        end

        def seal(key, plaintext, aad:)
          cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
          cipher.key = key
          iv = cipher.random_iv
          cipher.auth_data = aad.to_s
          ciphertext = cipher.update(plaintext.to_s) + cipher.final
          Base64.strict_encode64(iv + cipher.auth_tag(TAG_BYTES) + ciphertext)
        end

        def open(key, sealed, aad:)
          raw = Base64.strict_decode64(sealed.to_s)
          raise DecryptError, "sealed value too short" if raw.bytesize < IV_BYTES + TAG_BYTES

          cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
          cipher.key = key
          cipher.iv = raw.byteslice(0, IV_BYTES)
          cipher.auth_tag = raw.byteslice(IV_BYTES, TAG_BYTES)
          cipher.auth_data = aad.to_s
          plaintext = cipher.update(raw.byteslice((IV_BYTES + TAG_BYTES)..)) + cipher.final
          plaintext.force_encoding(Encoding::UTF_8)
        rescue ArgumentError, OpenSSL::Cipher::CipherError => e
          raise DecryptError, "cannot decrypt: #{e.class}"
        end
      end
    end
  end
end
