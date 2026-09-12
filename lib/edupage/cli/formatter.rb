require "json"
require "yaml"

module Edupage
  class CLI < Thor
    # Renders a resolver result for a terminal.
    #
    # JSON and YAML go through Serializer, the same one the REST API and the MCP server
    # use, so `--json` output is byte-identical across surfaces. The table view is the
    # only thing unique to the CLI; Table draws it.
    class Formatter
      def initialize(output: $stdout, format: :table, width: nil)
        @output = output
        @format = format
        @width = width || Table.terminal_width
      end

      def render(result, resource: nil)
        case @format
        when :json then @output.puts(JSON.pretty_generate(Serializer.call(result)))
        when :yaml then @output.puts(YAML.dump(deep_stringify(Serializer.call(result))))
        else render_table(result, resource)
        end
      end

      private

      def render_table(result, resource)
        records = result.is_a?(Relation) || result.is_a?(Array) ? result.to_a : [result]
        return @output.puts("No records.") if records.empty?

        fields = resource&.table_fields
        fields = default_fields(records.first) if fields.nil? || fields.empty?

        rows = records.map { |record| fields.map { |f| Serializer.field(record, f).to_s } }
        headers = fields.map { |f| Serializer.header(f) }
        @output.puts(Table.boxed(headers, rows, width: @width))
      end

      # Falls back to whatever the object reports, for resources with no table_fields.
      def default_fields(record)
        return record.to_h.keys if record.respond_to?(:to_h)

        [:to_s]
      end

      def deep_stringify(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, deep_stringify(v)] }
        when Array then value.map { |v| deep_stringify(v) }
        else value
        end
      end
    end
  end
end
