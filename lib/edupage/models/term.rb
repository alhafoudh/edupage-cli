module Edupage
  module Models
    # Half of a school year ("1. polrok"), as reported by yearterms.
    #
    # `grade_count` comes straight from Edupage and is the cheapest way to tell whether
    # a term is worth fetching at all.
    class Term < Model
      attribute :id, "term"
      attribute :name, "termName"
      attribute :year_id, "yearid"
      attribute :year_name, "yearName"
      attribute :starts_on, "dateFrom", cast: :date
      attribute :ends_on, "dateTo", cast: :date
      attribute :grade_count, "numGrades", cast: :integer

      attr_reader :year

      def initialize(data, school: nil, year: nil)
        super(data, school: school)
        @year = year
      end

      def short = id

      def grades = Relation.new(-> { year.grades_for(self) })

      def current?
        return false unless starts_on && ends_on

        (starts_on..ends_on).cover?(Date.today)
      end

      def to_s = "#{year_name} #{name} (#{grade_count} grades)"
    end
  end
end
