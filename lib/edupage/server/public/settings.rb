require "base64"
require "uri"

module Edupage
  module Server
    module Public
      # Configuration of `edupage server --public`, read from the environment.
      #
      # Everything that would be unsafe to guess - where the server is reachable from
      # outside, and the key that protects stored logins - must be given explicitly;
      # startup fails before binding a port otherwise.
      class Settings
        MIN_KEY_BYTES = 32
        LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze
        DEFAULT_DATA_DIR = "/data".freeze

        attr_reader :public_url, :pepper, :data_dir

        def self.from_env(env = ENV, public_url: nil)
          new(
            public_url: public_url || env["EDUPAGE_PUBLIC_URL"],
            secret_key: env["EDUPAGE_SECRET_KEY"],
            data_dir: env["EDUPAGE_DATA_DIR"] || DEFAULT_DATA_DIR,
            trust_proxy: env["EDUPAGE_TRUST_PROXY"].to_s == "1"
          )
        end

        def initialize(public_url:, secret_key:, data_dir:, trust_proxy: false)
          @public_url = normalize_url(public_url)
          @pepper = decode_key(secret_key)
          @data_dir = data_dir
          @trust_proxy = trust_proxy
        end

        def issuer = public_url
        def resource = "#{public_url}/mcp"
        def host = URI(public_url).host
        def trust_proxy? = @trust_proxy

        def inspect = "#<#{self.class.name} public_url=#{public_url.inspect} data_dir=#{data_dir.inspect}>"
        alias to_s inspect

        private

        def normalize_url(value)
          url = value.to_s.strip.chomp("/")
          if url.empty?
            raise Error, "Set EDUPAGE_PUBLIC_URL (or --public-url) to the https URL this server is reachable at."
          end

          uri = URI(url)
          https = uri.scheme == "https"
          local_http = uri.scheme == "http" && LOCAL_HOSTS.include?(uri.host)
          unless (https || local_http) && uri.host && !uri.host.empty?
            raise Error, "EDUPAGE_PUBLIC_URL must be an https URL (plain http only for localhost), got #{url.inspect}."
          end

          url
        rescue URI::InvalidURIError
          raise Error, "EDUPAGE_PUBLIC_URL is not a valid URL: #{url.inspect}."
        end

        # Hex first (a hex string is always valid base64 too, so it must win), then
        # base64, then the raw bytes, whichever yields enough key material.
        def decode_key(value)
          text = value.to_s.strip
          candidates = []
          candidates << [text].pack("H*") if text.match?(/\A(?:[0-9a-fA-F]{2})+\z/)
          candidates << begin
            Base64.strict_decode64(text)
          rescue ArgumentError
            nil
          end
          candidates << text.b
          key = candidates.compact.find { |bytes| bytes.bytesize >= MIN_KEY_BYTES }
          return key if key

          raise Error, "Set EDUPAGE_SECRET_KEY to at least #{MIN_KEY_BYTES} random bytes, " \
                       "e.g. the output of `openssl rand -base64 32`."
        end
      end
    end
  end
end
