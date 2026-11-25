require "json"
require "rack/utils"
require "sinatra/base"
require "uri"

module Edupage
  module Server
    module Public
      # HTTP surface of `edupage server --public`: OAuth metadata and endpoints, the
      # Edupage login pages, and /mcp. The REST API is deliberately not mounted here.
      class App < Sinatra::Base
        configure do
          set :show_exceptions, false
          set :raise_errors, false
          set :logging, false
          set :views, File.join(__dir__, "views")
          # The public host is validated by the MCP transport and by the issuer in
          # metadata; Sinatra's own host list would only break reverse proxies.
          set :host_authorization, { permitted_hosts: [] }
        end

        class << self
          attr_reader :deps

          def configure_with(**deps)
            @deps = deps
          end
        end

        helpers do
          def h(value) = Rack::Utils.escape_html(value.to_s)

          def deps = self.class.deps
          def public_settings = deps.fetch(:settings)
          def clients = deps.fetch(:clients)
          def grants = deps.fetch(:grants)
          def flow = deps.fetch(:flow)
          def pending = deps.fetch(:pending)

          def url(path) = "#{public_settings.issuer}#{path}"

          def json_response(status_code, payload, headers = {})
            content_type :json
            headers.each { |key, value| response.headers[key] = value }
            halt status_code, JSON.generate(payload)
          end

          def page(template, status_code: 200, **locals)
            content_type :html
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["Referrer-Policy"] = "no-referrer"
            response.headers["Content-Security-Policy"] = csp(locals[:form_target])
            halt status_code, erb(template, locals: locals)
          end

          def csp(redirect_target)
            form_action = ["'self'", redirect_target].compact.join(" ")
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " \
              "form-action #{form_action}; frame-ancestors 'none'"
          end

          def notice(message, status_code: 400)
            page(:notice, status_code: status_code, message: message)
          end

          def client_ip
            public_settings.trust_proxy? ? request.ip : request.env["REMOTE_ADDR"]
          end

          def authorization_error(redirect_uri, error, state)
            redirect flow.redirect(redirect_uri, "error" => error, "state" => state, "iss" => public_settings.issuer)
          end

          # The pending login named by the form, with its CSRF token checked.
          def pending_auth!(check_csrf: true)
            auth = pending.find(params["pending_id"])
            notice(FINISHED) unless auth
            if check_csrf && !Crypto.secure_equal?(params["csrf"].to_s, auth.csrf)
              notice("Formulár je neplatný. Začni znova v aplikácii, z ktorej si sa pripájal.", status_code: 403)
            end
            auth
          end

          def two_factor_path(auth) = "/oauth/authorize/two-factor?pending_id=#{URI.encode_www_form_component(auth.id)}"

          def finish!(auth)
            target = flow.finish(auth)
            redirect target
          rescue LoginFlow::NothingUsable
            notice(NOTHING_USABLE)
          rescue LoginFlow::Finished
            notice(FINISHED)
          end

          # For the polling endpoint: where to go once the login is done.
          def finish_url(auth)
            flow.finish(auth)
          rescue LoginFlow::NothingUsable, LoginFlow::Finished
            nil
          end

          # Edupage failing while starting the second factor ends on a page with a way
          # forward, never on an error dump; a reload tries again.
          def render_two_factor(auth, error: nil, status_code: 200)
            info = begin
              flow.current_two_factor(auth)
            rescue Edupage::Error => e
              Edupage.logger.warn("Two-factor step failed: #{e.class}")
              notice(UNREACHABLE, status_code: 502)
            end
            finish!(auth) unless info

            school, position, total = flow.progress(auth)
            Edupage.logger.info("Two-factor step #{position}/#{total} (#{info.channel})")
            page(:two_factor, status_code: status_code, auth: auth, info: info, error: error,
                              school: school, position: position, total: total, retry_in: params["retry"].to_i,
                              form_target: redirect_origin(auth))
          end

          # Runs a 2FA action against Edupage; a failure re-renders the page with a note.
          def two_factor_action(auth)
            yield
          rescue Edupage::Error => e
            Edupage.logger.warn("Two-factor action failed: #{e.class}")
            render_two_factor(auth, error: "Edupage teraz neodpovedá. Skús to znova.")
          end

          # Browsers apply form-action to the redirect that follows a form post, and the
          # last post of the login redirects to the client.
          def redirect_origin(auth)
            uri = URI(auth.oauth[:redirect_uri])
            port = uri.port == uri.default_port ? "" : ":#{uri.port}"
            "#{uri.scheme}://#{uri.host}#{port}"
          end

          def render_login(auth, error: nil, status_code: 200)
            oauth = auth.oauth
            redirect_host = URI(oauth[:redirect_uri]).host
            page(:login, status_code: status_code, auth: auth, error: error,
                         client_name: oauth[:client_name], redirect_host: redirect_host,
                         claude: clients.claude?(oauth[:redirect_uri]),
                         form_target: redirect_origin(auth))
          end
        end

        FINISHED = "Toto prihlásenie už skončilo alebo vypršalo. Začni znova v aplikácii, z ktorej si sa pripájal.".freeze
        UNREACHABLE = "Edupage sa nepodarilo kontaktovať. Skús to znova o chvíľu.".freeze
        NOTHING_USABLE ="Ani jedna škola z tohto účtu sa nedala pripojiť. Začni znova v aplikácii, " \
                         "z ktorej si sa pripájal.".freeze

        get "/healthz" do
          content_type :json
          JSON.generate(status: "ok", version: VERSION)
        end

        # --- metadata ------------------------------------------------------------------

        ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"].each do |path|
          get path do
            json_response 200, resource: public_settings.resource,
                               authorization_servers: [public_settings.issuer],
                               bearer_methods_supported: ["header"]
          end
        end

        get "/.well-known/oauth-authorization-server" do
          json_response 200,
                        issuer: public_settings.issuer,
                        authorization_endpoint: url("/oauth/authorize"),
                        token_endpoint: url("/oauth/token"),
                        registration_endpoint: url("/oauth/register"),
                        revocation_endpoint: url("/oauth/revoke"),
                        response_types_supported: ["code"],
                        grant_types_supported: %w[authorization_code refresh_token],
                        code_challenge_methods_supported: ["S256"],
                        token_endpoint_auth_methods_supported: ["none"],
                        client_id_metadata_document_supported: true
        end

        # --- registration --------------------------------------------------------------

        post "/oauth/register" do
          body = JSON.parse(request.body.read)
          json_response 400, error: "invalid_client_metadata", error_description: "JSON object expected" unless body.is_a?(Hash)

          json_response 201, clients.register(body)
        rescue JSON::ParserError
          json_response 400, error: "invalid_client_metadata", error_description: "JSON object expected"
        rescue Clients::InvalidMetadata => e
          json_response 400, error: "invalid_client_metadata", error_description: e.message
        end

        # --- authorization -------------------------------------------------------------

        get "/oauth/authorize" do
          client = clients.find(params["client_id"])
          notice("Neznáma aplikácia. Pripojenie sa nedá dokončiť.") unless client

          redirect_uri = params["redirect_uri"].to_s
          unless clients.redirect_matches?(client, redirect_uri)
            notice("Adresa návratu nepatrí tejto aplikácii. Pripojenie sa nedá dokončiť.")
          end

          state = params["state"]
          authorization_error(redirect_uri, "unsupported_response_type", state) unless params["response_type"] == "code"
          if params["code_challenge"].to_s.empty? || params["code_challenge_method"] != "S256"
            authorization_error(redirect_uri, "invalid_request", state)
          end
          resource = params["resource"]
          if resource && !resource.empty? && resource.chomp("/") != public_settings.resource
            authorization_error(redirect_uri, "invalid_target", state)
          end

          auth = pending.create(client_id: client.id, redirect_uri: redirect_uri, state: state,
                                code_challenge: params["code_challenge"], resource: public_settings.resource,
                                client_name: client.name)
          render_login(auth)
        end

        post "/oauth/authorize" do
          auth = pending_auth!
          result = flow.submit_password(auth, school: params["school"], username: params["username"],
                                              password: params["password"], ip: client_ip)
          result == :done ? finish!(auth) : redirect(two_factor_path(auth))
        rescue LoginFlow::InvalidSchool
          render_login(auth, error: "Neplatná škola. Zadaj začiatok adresy školy, napr. zsmojaskola.",
                             status_code: 400)
        rescue Edupage::NotFoundError
          school = params["school"].to_s.strip.downcase.delete_suffix(".edupage.org")
          render_login(auth, error: "Škola #{school} na Edupage neexistuje. Skontroluj začiatok adresy školy.",
                             status_code: 400)
        rescue LoginFlow::Blocked
          render_login(auth, error: "Príliš veľa neúspešných pokusov. Skús to znova o 15 minút.", status_code: 429)
        rescue LoginFlow::BadCredentials
          render_login(auth, error: "Nesprávne meno alebo heslo.", status_code: 401)
        rescue Edupage::Error => e
          # Our own RequestError messages carry only the school and the HTTP status or
          # error class, never credentials.
          detail = e.is_a?(RequestError) ? ": #{e.message}" : ""
          Edupage.logger.warn("Login against Edupage failed: #{e.class}#{detail}")
          render_login(auth, error: UNREACHABLE, status_code: 502)
        end

        # --- two-factor ----------------------------------------------------------------

        get "/oauth/authorize/two-factor" do
          auth = pending_auth!(check_csrf: false)
          if params["poll"] == "1"
            result = two_factor_action(auth) { flow.poll(auth) }
            finish!(auth) if result == :done
          end
          render_two_factor(auth)
        end

        # A failed poll is only a missed beat: the page keeps polling.
        post "/oauth/authorize/two-factor/poll" do
          auth = pending_auth!
          result = begin
            flow.poll(auth)
          rescue Edupage::Error => e
            Edupage.logger.warn("Two-factor poll failed: #{e.class}")
            :waiting
          end

          case result
          when :waiting then json_response 200, state: "waiting"
          when :expired then json_response 200, state: "expired"
          when :next then json_response 200, state: "next", redirect: two_factor_path(auth)
          else
            target = finish_url(auth)
            json_response 200, state: "done", redirect: target || two_factor_path(auth)
          end
        end

        post "/oauth/authorize/two-factor/code" do
          auth = pending_auth!
          case two_factor_action(auth) { flow.submit_code(auth, params["code"]) }
          when :invalid then render_two_factor(auth, error: "Nesprávny kód.", status_code: 400)
          when :next then redirect two_factor_path(auth)
          else finish!(auth)
          end
        end

        post "/oauth/authorize/two-factor/resend" do
          auth = pending_auth!
          two_factor_action(auth) { flow.resend_push(auth) }
          redirect two_factor_path(auth)
        end

        post "/oauth/authorize/two-factor/email" do
          auth = pending_auth!
          answer = two_factor_action(auth) { flow.send_email(auth) }
          suffix = answer.is_a?(Integer) ? "&retry=#{answer}" : ""
          redirect "#{two_factor_path(auth)}#{suffix}"
        end

        post "/oauth/authorize/two-factor/skip" do
          auth = pending_auth!
          flow.skip(auth) == :next ? redirect(two_factor_path(auth)) : finish!(auth)
        end

        # --- tokens --------------------------------------------------------------------

        post "/oauth/token" do
          no_store = { "Cache-Control" => "no-store", "Pragma" => "no-cache" }
          tokens =
            case params["grant_type"]
            when "authorization_code"
              grants.exchange_code(params["code"], client_id: params["client_id"],
                                                   redirect_uri: params["redirect_uri"],
                                                   code_verifier: params["code_verifier"])
            when "refresh_token"
              grants.refresh(params["refresh_token"], client_id: params["client_id"])
            else
              json_response 400, { error: "unsupported_grant_type" }, no_store
            end

          json_response 200, { access_token: tokens.access_token, token_type: "Bearer",
                               expires_in: tokens.expires_in, refresh_token: tokens.refresh_token }, no_store
        rescue Grants::InvalidGrant => e
          json_response 400, { error: "invalid_grant", error_description: e.message }, no_store
        end

        post "/oauth/revoke" do
          grants.revoke(params["token"])
          status 200
          ""
        end

        # --- MCP -----------------------------------------------------------------------

        %i[get post delete].each do |verb|
          public_send(verb, "/mcp") { serve_mcp }
        end

        helpers do
          # The token comes from the Authorization header only, never the query string.
          def serve_mcp
            token = request.env["HTTP_AUTHORIZATION"].to_s[/\ABearer\s+(\S+)\z/i, 1]
            unauthorized! unless token

            describe_mcp_request

            unlocked = grants.unlock(token)
            context = {
              grant_id: unlocked.grant_id,
              credentials: unlocked.credentials,
              account_provider: ->(&blk) { deps.fetch(:runtimes).with_account(unlocked.grant_id, unlocked.credentials, &blk) }
            }
            status_code, headers, body = mcp_transport(context).handle_request(request)

            headers.each { |key, value| response.headers[key] = value }
            halt status_code, Array(body).join
          rescue Grants::InvalidToken
            unauthorized!
          end

          # Method and tool name for the access log. Arguments name pupils, so they never
          # reach the log; only names that look like identifiers are kept.
          def describe_mcp_request
            return unless request.post?

            message = JSON.parse(request.body.read)
            request.body.rewind
            messages = message.is_a?(Array) ? message : [message]
            names = messages.grep(Hash).filter_map do |m|
              method = m["method"].to_s
              next unless method.match?(%r{\A[\w/]{1,64}\z})

              tool = m.dig("params", "name").to_s if method == "tools/call"
              tool&.match?(/\A\w{1,64}\z/) ? "#{method} #{tool}" : method
            end
            request.env[RequestLog::DETAIL] = names.join(", ") unless names.empty?
          rescue JSON::ParserError
            request.body.rewind
          end

          def mcp_transport(context)
            ::MCP::Server::Transports::StreamableHTTPTransport.new(
              deps.fetch(:mcp).build_server(context),
              stateless: true, enable_json_response: true, allowed_hosts: [public_settings.host]
            )
          end

          def unauthorized!
            metadata = url("/.well-known/oauth-protected-resource/mcp")
            json_response 401, { error: "invalid_token" },
                          "WWW-Authenticate" => %(Bearer resource_metadata="#{metadata}", error="invalid_token")
          end
        end

        error Sinatra::NotFound do
          content_type :json
          JSON.generate(error: "not found")
        end

        # Class and location only: messages of lower layers are not vetted for secrets.
        error StandardError do
          failure = env["sinatra.error"]
          Edupage.logger.error("#{request.request_method} #{request.path_info} failed: #{failure.class} " \
                               "at #{Array(failure.backtrace).first(3).join(" < ")}")
          content_type :json
          status 500
          JSON.generate(error: "internal error")
        end
      end
    end
  end
end
