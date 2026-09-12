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

      def initialize(account_options: {})
        @account_options = account_options
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
        Registry.all.map { |resource| build_tool(resource) }
      end

      private

      def build_tool(resource)
        options = @account_options

        ::MCP::Tool.define(
          name: resource.tool_name,
          title: resource.name.to_s.tr("_", " ").capitalize,
          description: describe(resource),
          input_schema: input_schema(resource),
          annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
        ) do |**arguments|
          MCP.respond(resource, arguments, options)
        end
      end

      # Runs a resource and wraps the result the way MCP expects. Kept as a module
      # method so the tool blocks stay tiny and testable.
      def self.respond(resource, arguments, account_options)
        params = account_options.merge(arguments.transform_keys(&:to_sym))
        context = Registry::Context.new(
          account: Edupage.account(username: params[:username], school: params[:school]),
          school: params[:school], student: params[:student], year: params[:year]
        )
        payload = Serializer.call(resource.call(context, params))

        ::MCP::Tool::Response.new([{ type: "text", text: JSON.pretty_generate(payload) }])
      rescue Edupage::Error => e
        ::MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }], error: true)
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
