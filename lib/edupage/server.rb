module Edupage
  # `edupage server`: the REST API and the MCP endpoint in one process.
  module Server
    DEFAULT_HOST = "127.0.0.1".freeze
    DEFAULT_PORT = 4567

    module_function

    def start(host: nil, port: nil, token: nil, account_options: {}, public: false, public_url: nil)
      require "puma"
      require "rack"

      host ||= Edupage.config.server["host"] || DEFAULT_HOST
      port = (port || Edupage.config.server["port"] || DEFAULT_PORT).to_i
      # Public mode has its own authentication; the local bearer token is not involved.
      return Public.start(host: host, port: port, public_url: public_url) if public

      if token
        Edupage.config["server"] = Edupage.config.server.merge("token" => token)
        Edupage.config.save
      end

      Auth.check_binding!(host)
      resolved_token = Auth.token

      API.account_options = account_options
      API.mcp_server = MCP.new(account_options: account_options)

      announce(host, port, resolved_token)
      run(API, host: host, port: port)
    end

    def run(app, host:, port:)
      server = Puma::Server.new(app)
      server.add_tcp_listener(host, port)
      trap("INT") { server.stop }
      trap("TERM") { server.stop }
      server.run.join
    end

    def announce(host, port, token)
      base = "http://#{host}:#{port}"
      $stderr.puts <<~BANNER
        edupage #{VERSION}

          REST   #{base}/api/v1/...
          MCP    #{base}/mcp
          health #{base}/healthz

          token  #{token}

        Example:
          curl -H "Authorization: Bearer #{token}" #{base}/api/v1/schools

        Stored in #{Edupage.config.path}. Ctrl-C to stop.
      BANNER
    end
  end
end
