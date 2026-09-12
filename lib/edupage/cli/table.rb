require "strings"
require "tty-screen"
require "tty-table"
require "unicode/display_width"

module Edupage
  class CLI < Thor
    # The one place tty-table is configured.
    #
    # Two shapes cover every aligned thing the CLI prints: #boxed for a result set
    # (unicode frame, header row) and #plain for a short aligned list with no frame,
    # such as the school/student/year block above a table.
    #
    # TTY::Table is always written out in full here - a bare `Table` inside this
    # namespace is this module, not tty-table's.
    module Table
      # Below this a column carries no information, so shrinking stops there and the
      # table is allowed to stay wider than the terminal.
      MIN_COLUMN_WIDTH = 12

      # One space of padding on each side of every column, inside the frame.
      BOXED_PADDING = [0, 1].freeze

      # The borderless renderer already separates columns with a single space, so its
      # own padding would only make a label/value block airy.
      PLAIN_PADDING = [0, 0].freeze

      module_function

      # A framed table with a header row.
      def boxed(headers, rows, width: terminal_width)
        # Unicode borders cost one vertical bar per column plus the closing one, on
        # top of the two padding spaces each column already takes.
        overhead = 3 * headers.size + 1
        widths = fit(::TTY::Table.new(headers, rows), width, overhead)

        table = ::TTY::Table.new(wrap(headers, widths), rows.map { |row| wrap(row, widths) })
        table.render(:unicode, width: canvas(widths, overhead, width), column_widths: widths,
                               multiline: true, padding: BOXED_PADDING)
      end

      # An aligned list with no border and no header: label/value pairs, candidate
      # lists, anything that used to be built with ljust.
      def plain(rows, width: terminal_width, indent: 0)
        return "" if rows.empty?

        # The null border draws nothing; the single space between columns is all there
        # is on top of the content.
        overhead = rows.first.size - 1
        widths = fit(::TTY::Table.new(rows), width - indent, overhead)

        table = ::TTY::Table.new(rows.map { |row| wrap(row, widths) })
        rendered = table.render(:basic, width: canvas(widths, overhead, width - indent),
                                        column_widths: widths,
                                        multiline: true, padding: PLAIN_PADDING)

        # Indented here rather than through the renderer's own :indent option, which
        # only reaches the first line of a row and leaves wrapped continuations hanging
        # to the left of the column they belong to.
        #
        # The renderer also pads the last column out to its full width; nothing follows
        # it, so that is just trailing whitespace.
        rendered.lines.map { |line| line.rstrip.empty? ? "" : "#{" " * indent}#{line.rstrip}" }
                .join("\n")
      end

      def terminal_width = ::TTY::Screen.width

      # Natural column widths, narrowed until the table fits the terminal.
      #
      # tty-table's own `resize: true` splits the width evenly between columns, which
      # squeezes short ones like `value` and wraps their headers for no reason. The
      # budget comes off the widest column instead: dates and marks stay whole and
      # only the free-text column gives ground.
      def fit(table, width, overhead)
        widths = ::TTY::Table::Columns.widths_from(table)
        budget = width - overhead

        while widths.sum > budget
          widest = widths.each_index.max_by { |index| widths[index] }
          break if widths[widest] <= MIN_COLUMN_WIDTH

          widths[widest] -= 1
        end

        widths
      end

      # The width handed to the renderer. Once every column is down to
      # MIN_COLUMN_WIDTH the table can still be wider than the terminal - a timetable
      # has six columns and a narrow window. Reporting the real total keeps it
      # horizontal and lets the terminal wrap the overflow; a width it does not fit in
      # makes tty-table flip the whole thing into vertical orientation and print a
      # warning on stdout, which is worse and would end up in a pipe.
      def canvas(widths, overhead, width) = [width, widths.sum + overhead].max

      # Breaks the cells across lines before tty-table sees them, so the renderer has
      # nothing left to wrap.
      #
      # strings 0.2.1, which tty-table wraps with, can return a line one character
      # wider than asked for. In Strings::Wrap.format_line a word that ends exactly on
      # the boundary leaves the line buffer empty; the space that follows it is then
      # flushed as an empty line and glued onto the next word, which comes back out one
      # character over - Strings.wrap("Slovenský jazyk", 9) gives "\nSlovenský \njazyk".
      # Inside a frame that single character tears the border open.
      #
      # Wrapping one column short absorbs it: an overlong line still fits. That costs a
      # character, so it is only done for the cells that actually trip the bug.
      def wrap(cells, widths)
        cells.each_with_index.map do |cell, index|
          text = cell.to_s
          width = widths[index]
          next text if fits?(text, width)

          lines = wrap_lines(text, width)
          lines = wrap_lines(text, width - 1) if width > 1 && spoiled?(lines, width)
          # The leading empty line the bug emits carries no content of its own.
          lines.shift while lines.first&.empty?
          lines.join("\n")
        end
      end

      def wrap_lines(text, width) = ::Strings.wrap(text, width).lines.map(&:chomp)

      def spoiled?(lines, width)
        lines.first&.empty? || lines.any? { |line| ::Unicode::DisplayWidth.of(line) > width }
      end

      # A cell already inside its column is handed over untouched: the renderer has
      # nothing to wrap, so it cannot widen it either.
      def fits?(text, width)
        text.lines.all? { |line| ::Unicode::DisplayWidth.of(line.chomp) <= width }
      end
    end
  end
end
