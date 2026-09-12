module Edupage
  module Models
    # A pupil. For a parent account these are the account's own children, which is the
    # entry point to everything year- and child-scoped.
    class Student < Person
      USER_STRING_PREFIX = "Student".freeze

      attribute :number_in_class, "numberinclass", cast: :integer
      attribute :number, "number", cast: :integer
      attribute(:school_class) { |d| school&.school_class(d["classid"]) }
      attribute(:parents) do |d|
        %w[parent1id parent2id parent3id].filter_map { |key| school&.parent(d[key]) }
      end

      def class_name = school_class&.name

      # --- year-scoped navigation -------------------------------------------------
      # Grades and terms only exist within a school year, and Edupage keeps the
      # selected year in the session, so they hang off a Year rather than the student.

      def years = school.years_for(self)

      def year(id)
        years.find { |y| y.id == id.to_s } or
          raise NotFoundError, "#{full_name} has no school year #{id}"
      end

      def current_year = years.find(&:current?) || years.first

      # Convenience delegations: the common case is "this year".
      def grades(...) = current_year.grades(...)
      def terms(...) = current_year.terms(...)

      # --- child-scoped, year-agnostic --------------------------------------------

      def timetable(range = nil) = school.timetable_for(self, range)
      def lessons(date = nil) = school.lessons_for(self, date)
      def timeline = school.timeline_for(self)
      def assignments = school.assignments_for(self)
      def homeworks = assignments.where(type: Assignment::HOMEWORK_TYPES)

      def to_s = "#{full_name}#{class_name ? " (#{class_name})" : ""}"
    end
  end
end
