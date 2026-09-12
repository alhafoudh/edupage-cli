module Edupage
  module Models
    # One day of a student's timetable.
    class Day < Model
      attribute :timetable_number, "tt_num", cast: :integer
      attribute :timetable_day, "tt_day", cast: :integer
      attribute :timetable_week, "tt_week", cast: :integer
      attribute :timetable_term, "tt_term", cast: :integer

      attr_reader :date

      def initialize(data, school: nil, date: nil)
        super(data, school: school)
        @date = date.is_a?(String) ? Date.parse(date) : date
      end

      # Real lessons only; Edupage pads the plan with empty period rows.
      def lessons
        @lessons ||= Relation.wrap(all_entries.select(&:lesson?))
      end

      # Including the structural rows, for anyone rendering a full grid.
      def entries = Relation.wrap(all_entries)

      def lesson_at(period) = lessons.find { |l| l.period_number.to_s == period.to_s }

      # Days off still come back with a plan, just without lessons.
      def teaching_day? = lessons.any?

      def absences = Array(data["student_absents"])

      def id = date&.iso8601
      def name = id

      # Compact one-line view of the day, used by the table renderers.
      def lesson_summary = lessons.map { |l| l.subject&.short || "?" }.join(" ")

      def to_s = "#{id} #{lessons.map(&:to_s).join(" ")}"

      def to_h
        super.merge(date: id, lessons: lessons.map(&:to_h)).compact
      end

      private

      def all_entries
        @all_entries ||= Array(data["plan"]).map { |entry| Lesson.new(entry, school: school, date: date) }
      end
    end
  end
end
