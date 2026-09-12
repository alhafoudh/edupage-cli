require "json"
require "yaml"

module Edupage
  class CLI < Thor
    # Renders a resolver result for a terminal.
    #
    # JSON and YAML go through Serializer, the same one the REST API and the MCP server
    # use, so `--json` output is byte-identical across surfaces. The table view is the
    # only thing unique to the CLI.
    class Formatter
      # A single message body or noticeboard post can run to hundreds of characters,
      # which would stretch one column past every terminal and make the table useless.
      MAX_COLUMN_WIDTH = 60

      def initialize(output: $stdout, format: :table, max_width: MAX_COLUMN_WIDTH)
        @output = output
        @format = format
        @max_width = max_width
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
        print_table(headers, rows)
      end

      # Falls back to whatever the object reports, for resources with no table_fields.
      def default_fields(record)
        return record.to_h.keys if record.respond_to?(:to_h)

        [:to_s]
      end

      def print_table(headers, rows)
        widths = headers.each_with_index.map do |header, index|
          [[header.length, *rows.map { |row| width(row[index]) }].max, @max_width].min
        end

        @output.puts(format_row(headers, widths))
        @output.puts(widths.map { |w| "-" * w }.join("  "))
        rows.each { |row| @output.puts(format_row(row, widths)) }
      end

      def format_row(cells, widths)
        cells.each_with_index
             .map { |cell, i| pad(truncate(single_line(cell), widths[i]), widths[i]) }
             .join("  ").rstrip
      end

      def truncate(value, width)
        return value if value.length <= width

        "#{value[0, width - 1]}…"
      end

      # Homework titles routinely contain newlines; a table row must stay one line.
      def single_line(value) = value.to_s.gsub(/\s*\n\s*/, " / ")

      def pad(value, width) = value + " " * [width - width(value), 0].max

      def width(value) = single_line(value).length

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
