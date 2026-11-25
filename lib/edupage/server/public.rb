require "fileutils"

module Edupage
  module Server
    # `edupage server --public`: MCP for anyone who has the URL, behind a built-in
    # OAuth server whose login form takes the Edupage login. See
    # docs/superpowers/specs/2026-11-25-public-mcp-oauth-design.md.
    module Public
      Components = Struct.new(:settings, :store, :grants, :clients, :pending, :rate_limiter, :runtimes, :flow,
                              :mcp, keyword_init: true)

      CLEANUP_INTERVAL = 3600

      module_function

      def components(settings)
        FileUtils.mkdir_p(settings.data_dir, mode: 0o700)
        store = Store.new(File.join(settings.data_dir, "edupage.sqlite3"))
        grants = Grants.new(store: store, pepper: settings.pepper)
        pending = Pending.new
        rate_limiter = RateLimiter.new
        runtimes = Runtimes.new(data_dir: settings.data_dir)
        # However a grant ends (revoked, replayed, expired, password changed), its live
        # account and its cached pupil data go with it.
        grants.on_delete = ->(grant_id) { runtimes.forget(grant_id) }
        flow = LoginFlow.new(pending: pending, rate_limiter: rate_limiter, grants: grants,
                             issuer: settings.issuer)
        Components.new(settings: settings, store: store, grants: grants, clients: Clients.new(store: store),
                       pending: pending, rate_limiter: rate_limiter, runtimes: runtimes, flow: flow,
                       mcp: MCP.new(public: true))
      end

      def build_app(settings, parts = components(settings))
        App.configure_with(settings: settings, clients: parts.clients, grants: parts.grants, flow: parts.flow,
                           pending: parts.pending, runtimes: parts.runtimes, mcp: parts.mcp)
        RequestLog.new(App)
      end

      def cleanup!(parts)
        parts.grants.cleanup!.each { |grant_id| parts.runtimes.forget(grant_id) }
        parts.runtimes.evict_idle!
        parts.pending.expire!
        sweep_orphaned_caches!(parts)
      end

      # Cache directories whose grant no longer exists, e.g. left by a crash.
      def sweep_orphaned_caches!(parts)
        Dir.glob(File.join(parts.settings.data_dir, "cache", "*")).each do |dir|
          grant_id = File.basename(dir)
          next unless grant_id.match?(Runtimes::GRANT_ID)

          parts.runtimes.forget(grant_id) unless parts.grants.find(grant_id)
        end
      end

      def start(host:, port:, public_url: nil)
        Store.require_sqlite!
        settings = Settings.from_env(ENV, public_url: public_url)
        parts = components(settings)
        app = build_app(settings, parts)
        Edupage.logger.level = ::Logger::INFO

        Thread.new do
          loop do
            sleep CLEANUP_INTERVAL
            cleanup!(parts)
          rescue StandardError => e
            Edupage.logger.error("Cleanup failed: #{e.class}")
          end
        end

        announce(settings, host, port)
        Server.run(app, host: host, port: port)
      end

      def announce(settings, host, port)
        $stderr.puts <<~BANNER
          edupage #{VERSION} (public mode)

            MCP     #{settings.resource}
            OAuth   #{settings.issuer}/.well-known/oauth-authorization-server
            listen  #{host}:#{port}
            data    #{settings.data_dir}

          Add #{settings.resource} to Claude as a custom connector. Ctrl-C to stop.
        BANNER
      end
    end
  end
end
