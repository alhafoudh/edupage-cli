require "mcp"

module Edupage
  module Server
    # MCP server exposing the same resources as the CLI and the REST API.
    #
    # Tools are generated from Registry, so the tool list, its arguments and their types
    # cannot diverge from the other surfaces. Every tool is read-only and says so, which
    # lets clients skip approval prompts.
    class MCP
      SERVER_NAME = "edupage".freeze

      INSTRUCTIONS = <<~TEXT.freeze
        Read-only access to an Edupage school account: schools, students, timetables,
        homework, and grades.

        Most data belongs to one student and one school year. Call edupage_students to
        find the students, and edupage_years to find which years hold data - in early
        autumn the current year is usually empty and the interesting grades are in the
        previous one. Pass `student` as a name or id and `year` as e.g. 2025.
      TEXT

      TWO_FACTOR_RECONNECT = "%<origin>s vyžaduje dvojstupňové overenie. Odpoj a znova pripoj " \
                             "Edupage konektor a potvrď prihlásenie.".freeze
      SESSION_EXPIRED = "Prihlásenie do Edupage pre %<origin>s vypršalo. Odpoj a znova pripoj Edupage konektor.".freeze

      # public: true builds the variant for `edupage server --public`: no username
      # argument, and the account comes from the request (server_context), never from
      # this machine's configuration.
      def initialize(account_options: {}, public: false)
        @account_options = account_options
        @public = public
      end

      def public? = @public

      # Public mode: a server per request, carrying that request's grant.
      def build_server(server_context)
        ::MCP::Server.new(
          name: SERVER_NAME, title: "Edupage", version: VERSION, instructions: INSTRUCTIONS,
          tools: tools, server_context: server_context
        )
      end

      def server
        @server ||= ::MCP::Server.new(
          name: SERVER_NAME,
          title: "Edupage",
          version: VERSION,
          instructions: INSTRUCTIONS,
          tools: tools
        )
      end

      # Blocks, serving MCP on stdin/stdout for editors and desktop clients.
      def run_stdio
        ::MCP::Server::Transports::StdioTransport.new(server).open
      end

      # Rack entry point for the /mcp endpoint of `edupage server`.
      def http_transport
        @http_transport ||= ::MCP::Server::Transports::StreamableHTTPTransport.new(
          server,
          stateless: true,
          enable_json_response: true
        )
      end

      def handle_http(request) = http_transport.handle_request(request)

      def tools
        @tools ||= Registry.all.map { |resource| public? ? build_public_tool(resource) : build_tool(resource) }
      end

      private

      def build_tool(resource)
        options = @account_options

        ::MCP::Tool.define(**tool_attributes(resource)) do |**arguments|
          MCP.respond(resource, arguments, options)
        end
      end

      def build_public_tool(resource)
        ::MCP::Tool.define(**tool_attributes(resource)) do |server_context:, **arguments|
          MCP.respond_public(resource, arguments, server_context)
        end
      end

      def tool_attributes(resource)
        {
          name: resource.tool_name,
          title: resource.name.to_s.tr("_", " ").capitalize,
          description: describe(resource),
          input_schema: input_schema(resource),
          annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
        }
      end

      # Runs a resource and wraps the result the way MCP expects. Kept as a module
      # method so the tool blocks stay tiny and testable.
      def self.respond(resource, arguments, account_options)
        params = account_options.merge(arguments.transform_keys(&:to_sym))
        account = Edupage.account(username: params[:username], school: params[:school])
        text_response(run(resource, account, params))
      rescue Edupage::Error => e
        error_response("Error: #{e.message}")
      end

      # Public mode: the account belongs to the grant behind the request. `username`
      # is dropped whatever the client sends, and a school whose two-factor approval
      # was skipped at login answers with how to fix it.
      def self.respond_public(resource, arguments, server_context)
        params = arguments.transform_keys(&:to_sym).except(:username)
        skipped = Array(server_context[:credentials]&.dig(:two_factor_origins))
        if params[:school] && skipped.include?(params[:school].to_s)
          return error_response(format(TWO_FACTOR_RECONNECT, origin: params[:school]))
        end

        payload = server_context[:account_provider].call { |account| run(resource, account, params) }
        text_response(payload)
      rescue TwoFactorRequiredError => e
        error_response(format(TWO_FACTOR_RECONNECT, origin: e.origin))
      rescue SessionExpiredError
        # No password is kept, so an ended Edupage session means connecting again.
        error_response(format(SESSION_EXPIRED, origin: params&.dig(:school) || "tvoj účet"))
      rescue Edupage::Error => e
        error_response("Error: #{e.message}")
      end

      def self.run(resource, account, params)
        context = Registry::Context.new(account: account, school: params[:school], student: params[:student],
                                        year: params[:year])
        Serializer.call(resource.call(context, params))
      end

      def self.text_response(payload)
        ::MCP::Tool::Response.new([{ type: "text", text: JSON.pretty_generate(payload) }])
      end

      def self.error_response(text)
        ::MCP::Tool::Response.new([{ type: "text", text: text }], error: true)
      end

      def describe(resource)
        scope_note =
          case resource.scope
          when :year then " Needs a student; year defaults to the current one."
          when :student then " Needs a student."
          else ""
          end

        "#{resource.summary}.#{scope_note}"
      end

      def input_schema(resource)
        properties = resource.all_params.to_h { |param| [param.name.to_s, param.json_schema] }
        required = resource.all_params.select(&:required).map { |p| p.name.to_s }

        { type: "object", properties: properties, required: required }
      end
    end
  end
end
