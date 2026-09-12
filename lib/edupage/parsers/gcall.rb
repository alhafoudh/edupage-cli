module Edupage
  module Parsers
    # Timetable for an arbitrary date range.
    #
    # /user/ only ever carries about four days. Anything wider goes through /gcall,
    # Edupage's generic widget RPC, which answers with a blob of JavaScript rather than
    # JSON - the payload sits in the second argument of a `classbook.fill(...)` call.
    class Gcall
      PATH = "/gcall".freeze
      CLASSBOOK_PATH = "/dashboard/eb.php?barNoSkin=1".freeze
      FILL = "classbook.fill".freeze

      def initialize(school)
        @school = school
      end

      # Returns { "2026-09-21" => {day payload}, ... } for the requested range.
      def load(student:, from:, to:)
        body = @school.session.with_cursor(child: student.id) do |session|
          session.post(PATH, {
            "gpid" => gpid(session),
            "gsh" => gsec_hash,
            "action" => "loadData",
            "datefrom" => from.iso8601,
            "dateto" => to.iso8601
          }).body
        end

        payload = Base.extract_blob(body, FILL, arg: 1)
        return {} unless payload

        payload["dates"] || {}
      end

      private

      def gsec_hash
        @school.document.gsec_hash or
          raise ParseError, "No gsecHash on the dashboard; /gcall cannot be called without it"
      end

      # The widget id is minted per page load and appears only in the class book page.
      def gpid(session)
        @gpid ||= begin
          ids = session.get(CLASSBOOK_PATH).body.scan(/gpid="?(\d+)"?/).flatten.uniq
          raise ParseError, "No gpid on the class book page" if ids.empty?

          ids.last
        end
      end
    end
  end
end
