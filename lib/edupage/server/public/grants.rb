require "base64"
require "digest"
require "json"
require "securerandom"

module Edupage
  module Server
    module Public
      # Lifecycle of one connected client for one Edupage login: authorization code,
      # access and refresh tokens, revocation and expiry.
      #
      # The login is sealed under a per-grant data key. The data key is stored only
      # wrapped under keys derived from the current token secrets (plus the server
      # pepper), so a request can unlock it and nothing else can.
      class Grants
        class InvalidGrant < StandardError; end
        class InvalidToken < StandardError; end

        Tokens = Struct.new(:grant_id, :access_token, :refresh_token, :expires_in, keyword_init: true)
        Unlocked = Struct.new(:grant_id, :credentials, keyword_init: true) do
          def inspect = "#<Unlocked grant_id=#{grant_id.inspect}>"
          alias_method :to_s, :inspect
        end

        CODE_TTL = 60
        ACCESS_TTL = 3600
        REFRESH_TTL = 90 * 86_400
        IDLE_GRANT_TTL = 90 * 86_400

        # A client refreshing twice with the same token (parallel requests hitting an
        # expired access token at once) is not an attack within this window.
        REUSE_GRACE = 60

        # on_delete is told about every deleted grant, so the caller can drop what it
        # keeps per grant (live account, cached pupil data).
        def initialize(store:, pepper:, clock: -> { Time.now.to_i }, on_delete: nil)
          @store = store
          @pepper = pepper
          @clock = clock
          @on_delete = on_delete
        end

        attr_writer :on_delete

        def now = @clock.call

        # Seals the login and returns [grant_id, authorization code].
        def issue_code(client_id:, credentials:, redirect_uri:, code_challenge:, resource:)
          grant_id = SecureRandom.hex(16)
          data_key = Crypto.random_key

          @store.transaction do
            @store.insert_grant(
              id: grant_id, client_id: client_id,
              sealed_credentials: Crypto.seal(data_key, JSON.generate(credentials), aad: grant_id),
              created_at: now, last_used_at: now
            )
            code = issue_token(grant_id, "ec", data_key, CODE_TTL,
                               extra: { "client_id" => client_id, "redirect_uri" => redirect_uri,
                                        "code_challenge" => code_challenge, "resource" => resource })
            [grant_id, code]
          end
        end

        def exchange_code(code_string, client_id:, redirect_uri:, code_verifier:)
          row, secret = authenticate(code_string, "ec", InvalidGrant)

          consume(row, "authorization code already used", grace: 0) do
            extra = row[:extra] || {}
            raise InvalidGrant, "authorization code expired" if row[:expires_at] <= now
            raise InvalidGrant, "client mismatch" unless extra["client_id"] == client_id
            raise InvalidGrant, "redirect_uri mismatch" unless extra["redirect_uri"] == redirect_uri
            raise InvalidGrant, "PKCE verification failed" unless pkce_ok?(code_verifier, extra["code_challenge"])

            data_key = unwrap(row, secret, InvalidGrant)
            @store.mark_token_used(row[:id], now)
            issue_pair(row[:grant_id], data_key)
          end
        end

        def refresh(refresh_string, client_id:)
          row, secret = authenticate(refresh_string, "er", InvalidGrant)

          consume(row, "refresh token reused", grace: REUSE_GRACE) do
            raise InvalidGrant, "refresh token expired" if row[:expires_at] <= now

            grant = @store.find_grant(row[:grant_id]) or raise InvalidGrant, "unknown grant"
            raise InvalidGrant, "client mismatch" unless grant[:client_id] == client_id

            data_key = unwrap(row, secret, InvalidGrant)
            @store.mark_token_used(row[:id], now)
            @store.delete_tokens(row[:grant_id], kind: "access")
            issue_pair(row[:grant_id], data_key)
          end
        end

        def unlock(access_string)
          row, secret = authenticate(access_string, "ea", InvalidToken)
          raise InvalidToken, "access token expired" if row[:expires_at] <= now

          grant = @store.find_grant(row[:grant_id]) or raise InvalidToken, "unknown grant"
          data_key = unwrap(row, secret, InvalidToken)
          credentials = JSON.parse(Crypto.open(data_key, grant[:sealed_credentials], aad: grant[:id]),
                                   symbolize_names: true)
          @store.touch_grant(grant[:id], now)
          Unlocked.new(grant_id: grant[:id], credentials: credentials)
        rescue Crypto::DecryptError
          raise InvalidToken, "cannot unlock grant"
        end

        # Re-seals the login of an unlocked grant, e.g. after a 2FA school was dropped.
        def reseal(access_string, credentials)
          row, secret = authenticate(access_string, "ea", InvalidToken)
          data_key = unwrap(row, secret, InvalidToken)
          @store.update_grant_credentials(row[:grant_id],
                                          Crypto.seal(data_key, JSON.generate(credentials), aad: row[:grant_id]))
        end

        # RFC 7009: unknown or broken tokens are not an error.
        def revoke(token_string)
          prefix, = Crypto.parse_token(token_string)
          return unless prefix

          row, = authenticate(token_string, prefix, InvalidToken)
          delete(row[:grant_id])
        rescue InvalidToken
          nil
        end

        def delete(grant_id)
          @store.delete_grant(grant_id)
          @on_delete&.call(grant_id)
        end

        def find(grant_id) = @store.find_grant(grant_id)

        # Returns the ids of the grants it deleted.
        def cleanup!(at = now)
          ids = @store.expired_grant_ids(at - IDLE_GRANT_TTL)
          ids.each { |id| delete(id) }
          @store.delete_expired_tokens(at)
          ids
        end

        def inspect = "#<#{self.class.name}>"

        private

        def authenticate(string, kind, error)
          prefix, id, secret = Crypto.parse_token(string)
          raise error, "malformed token" unless prefix == kind

          row = @store.find_token(id)
          raise error, "unknown token" unless row && row[:kind] == kind_name(kind)
          raise error, "unknown token" unless Crypto.secure_equal?(Crypto.digest(secret), row[:secret_hash])

          [row, secret]
        end

        # Runs the block in a transaction that first re-reads the token, so two
        # concurrent uses cannot both pass. A used code or refresh token coming back means
        # it leaked: the whole grant goes, unless it is back within `grace` seconds. The
        # deletion runs after the transaction, because the raise would otherwise roll it
        # back.
        def consume(row, message, grace:)
          used_at = nil
          result = @store.transaction do
            used_at = @store.find_token(row[:id])&.dig(:used_at)
            next nil if used_at

            yield
          end
          return result unless used_at
          raise InvalidGrant, message if grace.positive? && now - used_at <= grace

          delete(row[:grant_id])
          raise InvalidGrant, message
        end

        def kind_name(prefix) = { "ec" => "code", "ea" => "access", "er" => "refresh" }.fetch(prefix)

        def issue_pair(grant_id, data_key)
          access = issue_token(grant_id, "ea", data_key, ACCESS_TTL)
          refresh = issue_token(grant_id, "er", data_key, REFRESH_TTL)
          Tokens.new(grant_id: grant_id, access_token: access, refresh_token: refresh, expires_in: ACCESS_TTL)
        end

        def issue_token(grant_id, prefix, data_key, ttl, extra: nil)
          id, secret, string = Crypto.generate_token(prefix)
          @store.insert_token(
            id: id, grant_id: grant_id, kind: kind_name(prefix), secret_hash: Crypto.digest(secret),
            wrapped_key: Crypto.seal(wrapping_key(secret), Base64.strict_encode64(data_key), aad: "#{grant_id}:#{id}"),
            expires_at: now + ttl, used_at: nil, extra: extra
          )
          string
        end

        def unwrap(row, secret, error)
          Base64.strict_decode64(Crypto.open(wrapping_key(secret), row[:wrapped_key], aad: "#{row[:grant_id]}:#{row[:id]}"))
        rescue Crypto::DecryptError, ArgumentError
          raise error, "cannot unwrap grant key"
        end

        def wrapping_key(secret) = Crypto.derive_key(pepper: @pepper, secret: secret)

        def pkce_ok?(verifier, challenge)
          return false if verifier.to_s.empty? || challenge.to_s.empty?

          computed = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier.to_s), padding: false)
          Crypto.secure_equal?(computed, challenge.to_s)
        end
      end
    end
  end
end
