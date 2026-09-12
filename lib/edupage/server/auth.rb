module Edupage
  module Server
    # Bearer-token check for the HTTP surfaces.
    #
    # The server hands out a child's school record, so it binds to localhost and
    # requires a token by default. Binding anywhere else has to be asked for explicitly.
    module Auth
      LOOPBACK = %w[127.0.0.1 ::1 localhost].freeze

      module_function

      def token = Edupage.config.server_token

      def loopback?(host) = LOOPBACK.include?(host.to_s)

      # Refuses to expose the account to a network without a deliberate choice.
      def check_binding!(host)
        return if loopback?(host)

        Edupage.logger.warn(
          "Binding to #{host} makes this account reachable from the network; a token is required."
        )
      end

      def authorized?(request)
        presented = bearer(request) || request.params["token"]
        return false if presented.nil? || presented.empty?

        secure_compare(presented, token)
      end

      def bearer(request)
        header = request.env["HTTP_AUTHORIZATION"].to_s
        header[/\ABearer\s+(.+)\z/i, 1]
      end

      # Constant-time comparison; a token check that returns early leaks its prefix.
      def secure_compare(left, right)
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |result, (a, b)| result | (a ^ b) }.zero?
      end
    end
  end
end
