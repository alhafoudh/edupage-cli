module Edupage
  module Server
    module Public
      # One access-log line per request: method, path, status, duration. Query strings,
      # bodies and headers carry codes, tokens and passwords here, so none of them is
      # ever logged.
      #
      # The app may name what a request did in env[DETAIL] (the MCP endpoint puts the
      # JSON-RPC method and tool there); it is appended to the line.
      class RequestLog
        DETAIL = "edupage.log_detail".freeze

        def initialize(app)
          @app = app
        end

        def call(env)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status, headers, body = @app.call(env)
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          line = "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]} #{status} #{elapsed}ms"
          line = "#{line} #{env[DETAIL]}" if env[DETAIL]
          Edupage.logger.info(line)
          [status, headers, body]
        end
      end
    end
  end
end
