module Edupage
  module Parsers
    # Reads /znamky/, which carries a whole school year for the currently selected
    # child: the grades themselves, the events they hang off, and the list of years and
    # terms the child has data for.
    #
    # The page takes its year from the session cursor (see Session#set_year), so the
    # caller pins the year and this just reads whatever came back.
    class Znamky
      PATH = "/znamky/?barNoSkin=1".freeze
      VIEWER = "znamkyStudentViewer".freeze
      SETTINGS = "initZnamkovanieSettings".freeze

      # One request only ever returns one half-year, selected by `nadobdobie`. Asking
      # for a year therefore means asking for each of its terms and merging.
      def self.path_for(term: nil)
        term ? "#{PATH}&nadobdobie=#{term}" : PATH
      end

      def self.parse(html)
        new(Base.extract_blob!(html, VIEWER), settings: Base.extract_blob(html, SETTINGS) || {})
      end

      attr_reader :data, :settings

      def initialize(data, settings: {})
        @data = data
        @settings = settings
      end

      def student_id = data["studentid"]&.to_s
      def year_id = data["yearid"]&.to_s
      def year_name = data["skRok"]

      # The half-year this response covers.
      def term_id = data["nadobdobie"]&.to_s

      def grades = Array(data["vsetkyZnamky"])

      # Grades carry an event id but none of the interesting metadata; the title,
      # weight, class average and maximum points all live on the event.
      # Shape: { provider => { event_id => event } }
      def events
        @events ||= (data["vsetkyUdalosti"] || {}).each_with_object({}) do |(provider, rows), result|
          result[provider] = normalize(rows).to_h { |event| [event["UdalostID"].to_s, event] }
        end
      end

      def event_for(grade)
        events.dig(grade["provider"].to_s, grade["udalostid"].to_s)
      end

      # Every (year, term) pair the child has, each with how many grades are in it -
      # the cheapest way to find where the data actually is.
      def year_terms = Array(data["yearterms"])

      # Period definitions for the year, keyed by id (P1, KL1, V1, P2, ...).
      #
      # A grade's `mesiac` is one of these sub-periods, not the half-year itself: the
      # P2 response contains grades marked P2 and V2 ("vysvedčenie"). `nadobdobie`
      # points a sub-period at the half-year it belongs to.
      def periods = settings["obdobia"] || {}

      # Half-year a sub-period rolls up into; a half-year maps to itself.
      def parent_period(id)
        periods.dig(id.to_s, "nadobdobie") || id.to_s
      end

      # Subjects this child is graded in, which is a subset of the school's subjects.
      def subjects = normalize(data["predmety"])

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
