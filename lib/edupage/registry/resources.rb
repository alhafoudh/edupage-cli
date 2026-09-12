module Edupage
  # Every resource this tool exposes, declared once.
  #
  # Adding a resource here gives it a CLI command, a REST route and an MCP tool with no
  # further work; leaving one out of any surface is impossible by construction.
  class Registry
    # --- account ----------------------------------------------------------------------

    resource :account do
      scope :account
      summary "The logged-in account"
      table_fields :username, :name
      resolve ->(account, _) { account }
    end

    resource :schools do
      scope :account
      summary "Schools this account can reach"
      table_fields :origin, :name, :role
      resolve ->(account, _) { account.schools }
    end

    # --- school directory -------------------------------------------------------------
    #
    # These all read one /user/ document, so asking for several in a row costs one fetch.

    resource :students do
      scope :school
      summary "Students visible to the account (a parent sees their own children)"
      param :name, desc: "Filter by name"
      param :class, desc: "Filter by class, e.g. 2.A"
      table_fields :full_name, :class_name, :number_in_class
      resolve lambda { |school, p|
        school.students(year: p[:year]).where(name: p[:name], school_class: p[:class])
      }
    end

    resource :teachers do
      scope :school
      summary "Teachers"
      param :name, desc: "Filter by name or short code"
      table_fields :short, :full_name_with_titles
      resolve ->(school, p) { school.teachers(year: p[:year]).where(name: p[:name]) }
    end

    resource :parents do
      scope :school
      summary "Parents"
      param :name, desc: "Filter by name"
      table_fields :full_name
      resolve ->(school, p) { school.parents(year: p[:year]).where(name: p[:name]) }
    end

    resource :classes do
      scope :school
      summary "Classes"
      param :name, desc: "Filter by name"
      table_fields :name, :grade, :teacher
      resolve ->(school, p) { school.classes(year: p[:year]).where(name: p[:name]) }
    end

    resource :classrooms do
      scope :school
      summary "Rooms"
      param :name, desc: "Filter by name"
      table_fields :short, :name
      resolve ->(school, p) { school.classrooms(year: p[:year]).where(name: p[:name]) }
    end

    resource :subjects do
      scope :school
      summary "Subjects"
      param :name, desc: "Filter by name or short code"
      table_fields :short, :name
      resolve ->(school, p) { school.subjects(year: p[:year]).where(name: p[:name]) }
    end

    resource :periods do
      scope :school
      summary "The bell schedule"
      table_fields :name, :start_time, :end_time
      resolve ->(school, p) { school.periods(year: p[:year]) }
    end

    # --- student ----------------------------------------------------------------------

    resource :timetable do
      scope :student
      summary "Timetable days"
      param :date, type: :date, desc: "A single day (defaults to today)"
      param :from, type: :date, desc: "Start of a range"
      param :to, type: :date, desc: "End of a range"
      table_fields :date, :lesson_summary
      resolve lambda { |student, p|
        if p[:from] || p[:to]
          from = p[:from] || Date.today
          student.timetable(from..(p[:to] || from + 6))
        else
          Relation.wrap([student.timetable(p[:date])].compact)
        end
      }
    end

    resource :lessons do
      scope :student
      summary "Lessons on one day"
      param :date, type: :date, desc: "Defaults to today"
      param :subject, desc: "Filter by subject"
      table_fields :period_number, :subject, :teachers, :classrooms, :start_time, :end_time
      resolve ->(student, p) { student.lessons(p[:date]).where(subject: p[:subject]) }
    end

    resource :assignments do
      scope :student
      summary "Homework, tests, exams and projects"
      param :type, desc: "Filter by type, e.g. hw or test"
      param :subject, desc: "Filter by subject"
      param :due, type: :date, desc: "Only items due on or after this date"
      table_fields :due_on, :type, :subject, :title
      resolve lambda { |student, p|
        scope = student.assignments.where(type: p[:type], subject: p[:subject])
        scope = scope.where(due_on: p[:due]..) if p[:due]
        scope.order(:due_on)
      }
    end

    resource :homeworks do
      scope :student
      summary "Homework only, including tasks set to one pupil rather than the class"
      param :subject, desc: "Filter by subject"
      param :due, type: :date, desc: "Only items due on or after this date"
      table_fields :due_on, :subject, :title, :class_wide?
      resolve lambda { |student, p|
        scope = student.homeworks.where(subject: p[:subject])
        scope = scope.where(due_on: p[:due]..) if p[:due]
        scope.order(:due_on)
      }
    end

    resource :timeline do
      scope :student
      summary "The school feed for this student"
      param :type, desc: "Filter by item type, e.g. message or homework"
      table_fields :created_at, :type, :name
      resolve ->(student, p) { student.timeline.where(type: p[:type]).order(created_at: :desc) }
    end

    resource :years do
      scope :student
      summary "School years this student has data for"
      table_fields :id, :name, :current?, :grade_count
      resolve ->(student, _) { student.years }
    end

    # --- year -------------------------------------------------------------------------

    resource :terms do
      scope :year
      summary "Terms of a school year, with how many grades each holds"
      table_fields :id, :name, :starts_on, :ends_on, :grade_count
      resolve ->(year, _) { year.terms }
    end

    resource :grades do
      scope :year
      summary "Grades for a school year"
      param :term, type: :enum, values: %w[P1 P2], desc: "Half-year"
      param :subject, desc: "Filter by subject"
      table_fields :created_at, :subject, :value, :weight, :title
      resolve lambda { |year, p|
        year.grades.where(term: p[:term], subject: p[:subject]).order(:created_at)
      }
    end
  end
end
