module Edupage
  # A school year for one student - the level at which grades and terms exist.
  #
  # Edupage keeps the selected year in the session rather than in the request, so this
  # is a scope object rather than a fetched record: it remembers which (student, year)
  # it stands for and pins both cursors around every fetch it makes.
  class Year
    attr_reader :school, :student, :id, :name

    # term_rows are the yearterms entries for this year, already read while listing the
    # years. Keeping them means #terms and #grade_count cost nothing.
    def initialize(school:, student:, id:, name: nil, current: false, term_rows: nil)
      @school = school
      @student = student
      @id = id.to_s
      @name = name || "#{@id}/#{@id.to_i + 1}"
      @current = current
      @term_rows = term_rows
    end

    def current? = @current

    # Every grade in the year. Edupage serves one half-year per request, so this is the
    # union of the terms rather than a single fetch.
    def grades
      Relation.new(-> { terms.flat_map { |term| grades_for(term) } })
    end

    def terms
      Relation.new(-> { build_terms })
    end

    # Grades of one half-year.
    def grades_for(term)
      document = school.znamky_for(student, year: id, term: term.id)
      document.grades.map do |row|
        Models::Grade.new(row, school: school, event: document.event_for(row),
                               year: self, term: term)
      end
    end

    def term(id)
      terms.find { |t| t.id.to_s.casecmp?(id.to_s) } or
        raise NotFoundError, "#{student.full_name} has no term #{id} in #{name}"
    end

    def grade_count = terms.sum { |t| t.grade_count.to_i }

    # Year-scoped views of the school directory: dbi changes between years, so a class
    # list from 2025 is not the same as this year's.
    def classes = school.classes(year: id)
    def teachers = school.teachers(year: id)
    def subjects = school.subjects(year: id)

    def match_strings = [id, name].compact
    def matches?(query) = query.nil? || match_strings.any? { |c| c.casecmp?(query.to_s) }

    def to_h = { id: id, name: name, current: current?, grade_count: grade_count }
    def to_s = "#{name}#{current? ? " (current)" : ""}"
    def inspect = "#<Edupage::Year #{name} student=#{student.full_name.inspect}>"

    def ==(other) = other.is_a?(Year) && id == other.id && student == other.student
    alias eql? ==
    def hash = [Year, id, student.id].hash

    private

    def term_rows
      @term_rows ||= school.znamky_for(student, year: id).year_terms
                           .select { |row| row["yearid"].to_s == id }
    end

    def build_terms
      term_rows.map { |row| Models::Term.new(row, school: school, year: self) }
    end
  end
end
