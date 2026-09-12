module Edupage
  module Models
    # A class group such as "2.A". Named SchoolClass because `Class` is taken.
    class SchoolClass < Model
      attribute :name
      attribute :short
      attribute :grade, "grade", cast: :integer
      attribute(:teacher) { |d| school&.teacher(d["teacherid"]) }
      attribute(:classroom) { |d| school&.classroom(d["classroomid"]) }

      def students
        Relation.new(-> { school.students.select { |s| s.school_class == self } })
      end
    end
  end
end
