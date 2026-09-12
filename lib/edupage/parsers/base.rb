require "json"
require "strscan"

module Edupage
  module Parsers
    # Every Edupage page ships its data as an argument to a JavaScript call:
    #
    #   $j(document).ready(function() { ... .userhome({"dbi":{...}}); });
    #
    # The upstream JS library pulls these out with `fn\(([\s\S]*?)\);` which stops at
    # the first `);` - including one inside a string value, which does occur in message
    # bodies and homework titles. This scans for balanced brackets instead, so the
    # payload is extracted correctly regardless of its contents.
    module Base
      module_function

      # Returns the parsed JSON argument of the first call to +function+, or nil.
      #
      # +arg+ selects which argument to take. Most calls put the payload first, but
      # /gcall answers with `classbook.fill("Student113506", {...})`.
      def extract_blob(html, function, arg: 0)
        raw = extract_raw(html, function, arg: arg)
        return nil unless raw

        JSON.parse(raw)
      rescue JSON::ParserError => e
        raise ParseError.new("#{function}(...) argument #{arg} is not valid JSON: #{e.message}", snippet: raw)
      end

      def extract_blob!(html, function, arg: 0)
        extract_blob(html, function, arg: arg) or
          raise ParseError.new("Could not find #{function}(...) in the response", snippet: html)
      end

      # The literal source text of the first bracket-balanced argument.
      #
      # Scanning happens on a binary view of the document. StringScanner#pos counts
      # bytes while String#[] counts characters, and these pages are full of Slovak
      # diacritics - mixing the two silently walks off the end of a string literal and
      # starts counting brackets inside it.
      def extract_raw(html, function, arg: 0)
        bytes = html.b
        needle = function.b
        index = 0

        while (found = bytes.index(needle, index))
          index = found + needle.bytesize
          open = skip_spaces(bytes, index)
          next unless bytes[open] == "("

          start = argument_start(bytes, open, arg)
          next unless start && ["{", "["].include?(bytes[start])

          finish = match_bracket(bytes, start)
          return bytes[start..finish].force_encoding(Encoding::UTF_8) if finish
        end

        nil
      end

      # ASC settings are plain assignments rather than a call:
      #   ASC.gsechash = "803e65e8";
      #   ASC.gpid = 62780423;
      def extract_assignments(html, namespace)
        html.scan(/#{Regexp.escape(namespace)}\.([A-Za-z0-9_$]+)\s*=\s*([^\n;]*);/)
            .each_with_object({}) do |(key, value), result|
          value = value.strip
          next if value.start_with?("function")

          result[key] = (JSON.parse("[#{value}]").first rescue value)
        end
      end

      def skip_spaces(text, index)
        index += 1 while text[index] =~ /\s/
        index
      end

      BRACKETS = { "{" => "}", "[" => "]" }.freeze

      # Matches either a complete JSON string literal or a single structural bracket.
      #
      # Consuming whole string literals in one match is what makes this correct: values
      # in these payloads routinely contain brackets, and the timeline embeds an entire
      # JSON document as an escaped string, so brackets must only be counted outside
      # string literals.
      TOKEN = /"(?:[^"\\]|\\.)*"|[{}\[\]]/m.freeze

      # As TOKEN, plus the punctuation that separates call arguments.
      ARGUMENT_TOKEN = /"(?:[^"\\]|\\.)*"|[{}\[\](),]/m.freeze

      # Byte index where argument +wanted+ of a call begins, given the position of the
      # opening parenthesis. Commas inside strings, objects or nested calls do not
      # count as separators.
      def argument_start(text, open, wanted)
        return skip_spaces(text, open + 1) if wanted.zero?

        scanner = StringScanner.new(text)
        scanner.pos = open + 1
        depth = 0
        seen = 0

        while scanner.scan_until(ARGUMENT_TOKEN)
          token = scanner.matched
          next if token.start_with?('"')

          case token
          when "{", "[", "(" then depth += 1
          when "}", "]" then depth -= 1
          when ")"
            return nil if depth.zero? # argument list ended before we got there

            depth -= 1
          when ","
            next unless depth.zero?

            seen += 1
            return skip_spaces(text, scanner.pos) if seen == wanted
          end
        end

        nil
      end

      # Byte index of the bracket closing the one at +start+, or nil when unbalanced.
      # +text+ must be a binary string; see #extract_raw.
      def match_bracket(text, start)
        scanner = StringScanner.new(text)
        scanner.pos = start + 1
        stack = [BRACKETS[text[start]]]

        while scanner.scan_until(TOKEN)
          char = scanner.matched
          next if char.start_with?('"') # a whole string literal, skipped wholesale

          if BRACKETS.key?(char)
            stack.push(BRACKETS[char])
          else
            return nil unless char == stack.last

            stack.pop
            return scanner.pos - 1 if stack.empty?
          end
        end

        nil
      end
    end
  end
end
