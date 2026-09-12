module Edupage
  module Models
    # A single mark.
    #
    # Edupage splits a grade in two: the row in `vsetkyZnamky` holds the value and who
    # it belongs to, while everything descriptive - what it was for, how much it counts,
    # the class average - lives on the event it references. Both are merged here, with
    # the event kept under #event.
    class Grade < Model
      # p_typ_udalosti on the event: "1" is a classic 1-5 mark, "3" is points.
      TYPE_MARK = "1".freeze
      TYPE_POINTS = "3".freeze

      # Edupage stores weights as a percentage of a "normal" grade, where 20 means 1.0.
      WEIGHT_UNIT = 20.0

      attribute :id, "znamkaid"
      attribute :value, "data"
      # The sub-period the grade sits in: "P2" for ordinary marks, "V2" for the ones
      # that make up the end-of-term report. #term is the half-year it rolls up into.
      attribute :period, "mesiac"
      attribute :state, "stav"
      attribute :provider
      attribute :event_id, "udalostid"
      attribute :created_at, "datum", cast: :time
      attribute :signed_at, "podpisane", cast: :time
      attribute :signed_by_parent_at, "podpisane_rodic", cast: :time
      attribute(:subject) { |d| school&.subject(d["predmetid"]) }
      attribute(:student) { |d| school&.student(d["studentid"]) }
      attribute(:teacher) { |d| school&.teacher(d["ucitelid"]) }

      attr_reader :event, :year, :term

      def initialize(data, school: nil, event: nil, year: nil, term: nil)
        super(data, school: school)
        @event = event || {}
        @year = year
        @term = term
      end

      # --- from the event -------------------------------------------------------------

      def title = presence(event["p_meno"])
      def short = presence(event["p_skratka"])
      def type = event["p_typ_udalosti"]
      def due_on = Model.parse_date(event["p_termin"])
      def class_average = event["priemer"]&.to_f
      def school_class = school&.school_class(event["TriedaID"])

      def weight
        raw = event["p_vaha"]
        raw.nil? || raw.to_s.empty? ? 1.0 : raw.to_f / WEIGHT_UNIT
      end

      # --- derived --------------------------------------------------------------------

      def mark? = type == TYPE_MARK
      def points? = type == TYPE_POINTS

      def points = points? ? Float(value, exception: false) : nil

      def max_points
        return nil unless points?

        Float(event["p_vaha_body"], exception: false)
      end

      def percentage
        return nil unless points && max_points&.positive?

        (points / max_points * 100).round(2)
      end

      def signed? = !signed_at.nil?
      def signed_by_parent? = !signed_by_parent_at.nil?

      def name = title || value

      def match_strings = [id, value, title, short, subject&.short, subject&.name].compact.map(&:to_s)

      def to_s
        parts = [created_at&.strftime("%Y-%m-%d"), subject&.short, value]
        parts << "(#{title})" if title
        parts.compact.join(" ")
      end

      def to_h
        super.merge(
          title: title, weight: weight, type: type, points: points, max_points: max_points,
          percentage: percentage, class_average: class_average,
          year: year&.id, term: term&.id, signed_by_parent: signed_by_parent?
        ).compact
      end

      private

      def presence(value) = value.nil? || value.to_s.empty? ? nil : value.to_s
    end
  end
end
