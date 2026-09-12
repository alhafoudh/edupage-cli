module Edupage
  module Parsers
    # Reads /user/, which is the workhorse page: one fetch carries the whole school
    # directory (dbi), four days of timetable (dp), the timeline feed (items) and the
    # per-child group membership needed to attribute those items.
    #
    # Three separate payloads live in that HTML and all three matter:
    #   .userhome({...})   the data above
    #   .edubar({...})     session state - selected year, current child
    #   ASC.x = y;         school identity and the gsecHash needed by /gcall
    class Userhome
      def self.parse(html)
        new(
          Base.extract_blob!(html, ".userhome"),
          edubar: Base.extract_blob(html, ".edubar") || {},
          asc: Base.extract_assignments(html, "ASC")
        )
      end

      attr_reader :data, :edubar, :asc

      def initialize(data, edubar: {}, asc: {})
        @data = data
        @edubar = edubar
        @asc = asc
      end

      # --- school directory ---------------------------------------------------------

      def dbi = data["dbi"] || {}

      # dbi collections are keyed by id, except periods which arrive as an array.
      def collection(name) = normalize(dbi[name])

      # --- timetable ----------------------------------------------------------------

      def dates = data.dig("dp", "dates") || {}

      # --- timeline -----------------------------------------------------------------

      def items = Array(data["items"])

      # Maps a child id to every userstring that stands for them ("Student113506",
      # "Trieda-2", "CustPlan8503", ...). Timeline items are addressed to one of these,
      # so this is how a shared parent feed is split per child.
      def child_groups = data["childGroups"] || {}

      def parent_student_ids = Array(data["parentStudentids"]).map(&:to_s)

      # --- identity and session state -----------------------------------------------

      def user_id = data["userid"] || edubar["loggedUser"]
      def user_row = data["userrow"] || {}
      def user_name = edubar["loggedUserName"] || [user_row["p_meno"], user_row["p_priezvisko"]].compact.join(" ")
      def login = user_row["p_www_login"]
      def email = user_row["p_mail"]

      def school_name = asc["school_name"]
      def origin = asc["edupage"] || edubar["edupage"]
      def language = asc["lang"]
      def gsec_hash = asc["gsechash"]

      # The year the session is pointed at, which is not necessarily the current one.
      def selected_year = edubar["selectedYear"]&.to_s

      # The real current year, unaffected by the cursor.
      def current_year = edubar["autoYear"]&.to_s || selected_year

      def logged_child = edubar["loggedChild"]&.to_s

      def teaching_days = Array(edubar["vyucovacieDni"])

      private

      def normalize(value)
        case value
        when Hash then value.values
        when Array then value
        else []
        end
      end
    end
  end
end
