module Edupage
  module Models
    # A teacher. `short` is the code that appears in timetable cells.
    class Teacher < Person
      USER_STRING_PREFIX = "Ucitel".freeze

      attribute :short
      attribute :name_prefix, "nameprefix"
      attribute :name_suffix, "namesuffix"
      attribute :hidden_in_classbook, "cb_hidden", cast: :boolean
      attribute(:classroom) { |d| school&.classroom(d["classroomid"]) }

      alias hidden_in_classbook? hidden_in_classbook

      # "Mgr. Mária Kováčová, PhD."
      def full_name_with_titles
        leading = [name_prefix.to_s.strip, full_name].reject(&:empty?).join(" ")
        suffix = name_suffix.to_s.strip
        suffix.empty? ? leading : "#{leading}, #{suffix}"
      end

      def match_strings = (super + [short]).compact.reject(&:empty?).uniq
    end
  end
end
