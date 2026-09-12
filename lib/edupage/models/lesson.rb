module Edupage
  module Models
    # One entry in a day's plan.
    #
    # Edupage mixes real lessons with structural rows (empty periods, breaks); #lesson?
    # separates them. Each entry carries both a flat form (subjectid, teacherids, ...)
    # and a nested presentation form under "header"/"infos"; the flat form is used here
    # and the nested one is left in #data for anything not modelled.
    class Lesson < Model
      attribute :type
      attribute :period_number, "period"
      attribute :start_time, "starttime"
      attribute :end_time, "endtime"
      attribute :lesson_id, "lid"
      attribute(:groups) { |d| Array(d["groupnames"]).reject { |g| g.to_s.empty? } }
      attribute(:subject) { |d| school&.subject(d["subjectid"]) }
      attribute(:period) { |d| school&.period(d["period"]) }
      attribute(:teachers) { |d| Array(d["teacherids"]).filter_map { |id| school&.teacher(id) } }
      attribute(:classrooms) { |d| Array(d["classroomids"]).filter_map { |id| school&.classroom(id) } }
      attribute(:classes) { |d| Array(d["classids"]).filter_map { |id| school&.school_class(id) } }

      attr_reader :date

      def initialize(data, school: nil, date: nil)
        super(data, school: school)
        @date = date
      end

      def lesson? = type == "lesson"

      def teacher = teachers.first
      def classroom = classrooms.first

      # "Učivo: ..." - what was actually taught, when the teacher filled it in.
      def curriculum
        info_text("wd")&.sub(/\A[^:]*:\s*/, "")
      end

      def id = [date, period_number, data["subjectid"]].compact.join(":")

      def name = subject&.name
      def short = subject&.short

      def to_s
        return "#{period_number}. -" unless lesson?

        "#{period_number}. #{subject&.short || "?"}#{groups.empty? ? "" : " (#{groups.join(", ")})"}"
      end

      private

      def info_text(type)
        Array(data["infos"]).find { |info| info["type"] == type }
                            &.dig("texts", 0, "text")
      end
    end
  end
end
