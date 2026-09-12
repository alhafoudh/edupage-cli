module Edupage
  module Models
    # Shared shape of everyone Edupage knows about: students, teachers and parents all
    # carry the same name/gender/validity fields under the same keys.
    class Person < Model
      attribute :first_name, "firstname"
      attribute :last_name, "lastname"
      attribute :gender
      attribute :valid_from, "datefrom", cast: :date
      attribute :valid_to, "dateto", cast: :date
      attribute :inactive, "isOut", cast: :boolean

      alias inactive? inactive

      def full_name = [first_name, last_name].compact.join(" ").strip
      alias name full_name

      # Edupage addresses people by a typed string such as "Student113506" or
      # "Ucitel37135"; it appears all over the timeline payloads.
      def user_string = "#{self.class::USER_STRING_PREFIX}#{id}"

      def match_strings = (super + [full_name, user_string]).uniq
    end
  end
end
