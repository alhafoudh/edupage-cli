module Edupage
  module Models
    # Something the student has to do: homework, a test, an exam, a project.
    #
    # Edupage announces these as timeline items, in two shapes that the upstream JS
    # library treats very differently and which are unified here:
    #
    #   class-wide  recipient is a plan ("CustPlan8562"), the whole class gets it
    #   personal    recipient is the pupil ("Student113506")
    #
    # Both carry the real content in the embedded payload, so both are read the same
    # way. Only handling the first shape loses every individually assigned task - two
    # thirds of them on the account this was built against.
    class Assignment < TimelineItem
      HOMEWORK_TYPES = %w[hw etesthw].freeze
      EXAM_TYPES = %w[bexam sexam oexam rexam exam testing].freeze
      TEST_TYPES = %w[test etest etestprint].freeze
      PROJECT_TYPES = %w[pexam projekt].freeze

      # Timeline items that represent an assignment of some kind.
      TIMELINE_TYPES = %w[homework testpridelenie].freeze

      def self.assignment?(row)
        TIMELINE_TYPES.include?(row["typ"].to_s)
      end

      # "hw", "test", ... - the payload's own type, falling back to homework, which is
      # what a plain `homework` timeline item is.
      def assignment_type
        value = payload["typ"] || payload["etype"]
        value.to_s.empty? ? "hw" : value.to_s.split("|").first
      end
      alias type assignment_type

      def title = presence(payload["nazov"])
      def description = presence(payload["popis"])

      def due_on = Model.parse_date(payload["date"])
      def assigned_on = created_at&.to_date

      def subject = school&.subject(payload["predmetid"])
      def school_class = school&.school_class(payload["triedaid"])
      def teacher = owner.is_a?(Teacher) ? owner : nil

      def plan_id = payload["planid"]
      def super_id = payload["superid"] || payload["e_superid"]

      # True when the task went to a whole class rather than to one pupil.
      def class_wide? = recipient_user_string.to_s.start_with?("CustPlan", "Trieda", "Plan")

      def homework? = HOMEWORK_TYPES.include?(assignment_type)
      def exam? = EXAM_TYPES.include?(assignment_type)
      def test? = TEST_TYPES.include?(assignment_type)
      def project? = PROJECT_TYPES.include?(assignment_type)

      def overdue? = due_on ? due_on < Date.today : false

      def name = title
      def match_strings = [id, title, subject&.short, subject&.name, assignment_type].compact.map(&:to_s)

      def to_s
        [
          due_on ? "due #{due_on}" : nil,
          subject&.short,
          title
        ].compact.join(" | ")
      end

      def to_h
        {
          id: id, type: assignment_type, title: title, description: description,
          subject: subject&.name, teacher: teacher&.full_name,
          assigned_on: assigned_on&.iso8601, due_on: due_on&.iso8601,
          class_wide: class_wide?, student: student&.full_name
        }.compact
      end

      private

      def presence(value) = value.nil? || value.to_s.empty? ? nil : value.to_s
    end
  end
end
