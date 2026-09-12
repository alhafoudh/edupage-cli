require "json"

module Edupage
  module Parsers
    # The timeline is the school's activity feed: messages, homework, absences, canteen
    # menus, sign-ups, substitutions.
    #
    # For a parent it is a single feed covering every child, not one feed per child, so
    # nothing needs switching to read it - but each item has to be attributed. That is
    # what childGroups is for: it lists every userstring that stands for a given child
    # ("Student113506", "Trieda-2", "CustPlan8503", ...), and an item belongs to the
    # child whose list contains its recipient.
    class Timeline
      PATH = "/timeline/?akcia=getData".freeze

      attr_reader :items, :child_groups

      def initialize(items, child_groups: {})
        @items = Array(items)
        @child_groups = child_groups
      end

      # /user/ already carries the recent feed, so the common case needs no extra fetch.
      def self.from_userhome(document)
        new(document.items, child_groups: document.child_groups)
      end

      def self.parse(json, child_groups: {})
        payload = json.is_a?(String) ? JSON.parse(json) : json
        new(payload["items"] || payload["timelineItems"] || [], child_groups: child_groups)
      end

      # Userstrings that stand for the given student.
      def groups_for(student_id)
        Array(child_groups[student_id.to_s]).to_set
      end

      def for_student(student_id)
        groups = groups_for(student_id)
        return items if groups.empty?

        items.select { |item| groups.include?(item["user"].to_s) }
      end
    end
  end
end
