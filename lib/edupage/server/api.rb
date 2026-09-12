require "json"
require "sinatra/base"

module Edupage
  module Server
    # REST API and MCP endpoint.
    #
    # Routes are generated from Registry: the path comes from the resource's scope and
    # the query parameters from its declared filters, so a resource reachable from the
    # CLI is reachable here with the same name and the same options. Everything is GET;
    # this tool never writes to Edupage.
    class API < Sinatra::Base
      configure do
        set :show_exceptions, false
        set :raise_errors, false
        set :logging, false
        # Sinatra 4 rejects unexpected Host headers by default. What actually limits
        # exposure here is the bind address (loopback unless asked otherwise) plus the
        # bearer token, and the default list breaks reverse proxies and test clients
        # for no gain, so host checking is left off deliberately.
        set :host_authorization, { permitted_hosts: [] }
      end

      class << self
        attr_accessor :account_options, :mcp_server
      end

      before do
        content_type :json
        next if request.path_info == "/healthz"

        halt(401, error_body("Unauthorized: send Authorization: Bearer <token>")) unless Auth.authorized?(request)
      end

      get "/healthz" do
        content_type :json
        JSON.generate(status: "ok", version: VERSION)
      end

      # One route per resource, with the path shape dictated by the scope.
      Registry.each do |resource|
        get resource.rest_path do
          records = resolve(resource)
          payload = Serializer.call(records)

          JSON.pretty_generate(
            data: payload,
            meta: {
              resource: resource.name,
              count: payload.is_a?(Array) ? payload.size : 1
            }
          )
        end
      end

      # MCP over HTTP, so `edupage server` covers both surfaces.
      %i[get post delete].each do |verb|
        public_send(verb, "/mcp") do
          transport = self.class.mcp_server&.http_transport
          halt(503, error_body("MCP is not enabled on this server")) unless transport

          status, headers, body = transport.handle_request(request)
          headers.each { |key, value| response.headers[key] = value }
          halt(status, Array(body).join)
        end
      end

      # Error blocks set the status and return the body; halting from inside one
      # bypasses Sinatra's own response handling and yields the wrong status.
      # A level of the chain was left unspecified. The path normally makes that
      # impossible, but the answer still has to say what could have been chosen.
      error AmbiguousScopeError do
        error = env["sinatra.error"]
        status 400
        JSON.generate(error: error.message, level: error.level, candidates: error.candidates)
      end

      error NotFoundError do
        status 404
        error_body(env["sinatra.error"].message)
      end

      error MissingCredentialsError, LoginError, SessionExpiredError do
        status 401
        error_body(env["sinatra.error"].message)
      end

      error Edupage::Error do
        status 500
        error_body(env["sinatra.error"].message)
      end

      private

      def resolve(resource)
        merged = self.class.account_options.to_h.merge(symbolize(params))
        context = Registry::Context.new(
          account: Edupage.account(username: merged[:username], school: merged[:school]),
          school: merged[:school], student: merged[:student], year: merged[:year]
        )
        resource.call(context, merged)
      end

      def symbolize(hash)
        hash.to_h { |key, value| [key.to_sym, value] }
      end

      def error_body(message)
        JSON.generate(error: message)
      end
    end
  end
end
