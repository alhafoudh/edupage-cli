require "ipaddr"
require "json"
require "net/http"
require "securerandom"
require "socket"
require "uri"

module Edupage
  module Server
    module Public
      # OAuth clients: dynamic registration (RFC 7591) and Client ID Metadata Documents,
      # where the client_id is an https URL serving the client's metadata.
      #
      # Anyone may register (the owner's decision); the login page warns when the
      # redirect does not go to Claude.
      class Clients
        class InvalidMetadata < StandardError; end

        Client = Struct.new(:id, :name, :redirect_uris, :metadata_document, keyword_init: true) do
          def metadata_document? = metadata_document
        end

        CLAUDE_CALLBACK_HOSTS = %w[claude.ai claude.com].freeze
        LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1] ::1].freeze
        DOCUMENT_TTL = 600

        def initialize(store:, fetcher: MetadataFetcher.new, clock: -> { Time.now.to_i })
          @store = store
          @fetcher = fetcher
          @clock = clock
          @documents = {}
          @lock = Mutex.new
        end

        def register(params)
          redirect_uris = Array(params["redirect_uris"]).map(&:to_s)
          raise InvalidMetadata, "redirect_uris is required" if redirect_uris.empty?

          invalid = redirect_uris.reject { |uri| redirect_allowed?(uri) }
          raise InvalidMetadata, "redirect_uris not allowed: #{invalid.join(", ")}" unless invalid.empty?

          method = params["token_endpoint_auth_method"]
          if method && method != "none"
            raise InvalidMetadata, "only public clients are supported (token_endpoint_auth_method: none)"
          end

          id = SecureRandom.hex(16)
          metadata = {
            "client_id" => id,
            "client_id_issued_at" => @clock.call,
            "client_name" => params["client_name"].to_s[0, 200],
            "redirect_uris" => redirect_uris,
            "token_endpoint_auth_method" => "none",
            "grant_types" => %w[authorization_code refresh_token],
            "response_types" => ["code"]
          }
          @store.insert_client(id, metadata)
          metadata
        end

        def find(client_id)
          id = client_id.to_s
          return document_client(id) if id.start_with?("https://")

          row = @store.find_client(id)
          row && Client.new(id: id, name: row[:metadata]["client_name"],
                            redirect_uris: row[:metadata]["redirect_uris"], metadata_document: false)
        end

        def redirect_allowed?(uri)
          parsed = URI(uri)
          return false if parsed.fragment || parsed.host.to_s.empty?
          return true if parsed.scheme == "https"

          parsed.scheme == "http" && loopback?(parsed)
        rescue URI::InvalidURIError
          false
        end

        # Exact match, except that loopback redirects may use any port (RFC 8252).
        def redirect_matches?(client, uri)
          return true if client.redirect_uris.include?(uri)

          candidate = URI(uri)
          return false unless candidate.scheme == "http" && loopback?(candidate)

          client.redirect_uris.any? do |registered|
            reg = URI(registered)
            reg.scheme == "http" && reg.host == candidate.host && reg.path == candidate.path &&
              reg.query == candidate.query
          end
        rescue URI::InvalidURIError
          false
        end

        def claude?(redirect_uri)
          parsed = URI(redirect_uri)
          parsed.scheme == "https" && CLAUDE_CALLBACK_HOSTS.include?(parsed.host)
        rescue URI::InvalidURIError
          false
        end

        private

        def loopback?(uri) = LOOPBACK_HOSTS.include?(uri.host)

        def document_client(url)
          cached = @lock.synchronize { @documents[url] }
          return cached[:client] if cached && cached[:expires_at] > @clock.call

          document = @fetcher.call(url)
          return nil unless document && document["client_id"] == url

          uris = Array(document["redirect_uris"]).map(&:to_s).select { |uri| redirect_allowed?(uri) }
          return nil if uris.empty?

          client = Client.new(id: url, name: document["client_name"].to_s[0, 200], redirect_uris: uris,
                              metadata_document: true)
          @lock.synchronize { @documents[url] = { client: client, expires_at: @clock.call + DOCUMENT_TTL } }
          client
        end

        # Fetches a Client ID Metadata Document without letting the URL point the server
        # at anything internal: https only, public addresses only, no redirects, small.
        class MetadataFetcher
          MAX_BYTES = 16 * 1024
          TIMEOUT = 3

          def initialize(resolver: ->(host) { Addrinfo.getaddrinfo(host, 443, nil, :STREAM).map(&:ip_address) })
            @resolver = resolver
          end

          def call(url)
            uri = URI(url)
            return nil unless uri.scheme == "https" && uri.host

            address = public_address(uri.host) or return nil
            body = fetch(uri, address) or return nil
            parsed = JSON.parse(body)
            parsed.is_a?(Hash) ? parsed : nil
          rescue URI::InvalidURIError, JSON::ParserError, SocketError, SystemCallError, EOFError,
                 Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
            nil
          end

          private

          def public_address(host)
            addresses = @resolver.call(host)
            return nil if addresses.empty?
            return nil if addresses.any? { |ip| internal?(IPAddr.new(ip)) }

            addresses.first
          rescue IPAddr::InvalidAddressError, SocketError
            nil
          end

          # Ranges that are not the public internet, beyond what IPAddr knows itself:
          # "this network", CGNAT (also Tailscale), benchmarking, multicast and reserved,
          # NAT64 and the unspecified address.
          RESERVED = %w[0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 198.18.0.0/15 224.0.0.0/3
                        ::/128 64:ff9b::/96 ff00::/8].map { |range| IPAddr.new(range) }.freeze

          def internal?(ip)
            ip = ip.native if ip.ipv4_mapped?
            ip.private? || ip.loopback? || ip.link_local? ||
              RESERVED.any? { |range| range.family == ip.family && range.include?(ip) }
          end

          def fetch(uri, address)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            # Connect to the address we checked, so a second DNS answer cannot differ.
            http.ipaddr = address
            http.open_timeout = TIMEOUT
            http.read_timeout = TIMEOUT

            http.start do |connection|
              connection.request(Net::HTTP::Get.new(uri, "Accept" => "application/json")) do |response|
                return nil unless response.is_a?(Net::HTTPOK)

                body = +""
                response.read_body do |chunk|
                  body << chunk
                  return nil if body.bytesize > MAX_BYTES
                end
                return body
              end
            end
          end
        end
      end
    end
  end
end
