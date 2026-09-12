module Edupage
  module Models
    # One entry in the school feed.
    #
    # Edupage packs a second JSON document into the `data` field as a string; its shape
    # depends on the item type. #payload decodes it lazily.
    class TimelineItem < Model
      # The types worth naming; there are many more and they pass through as-is.
      TYPES = {
        "sprava" => :message,
        "nastenka" => :noticeboard,
        "homework" => :homework,
        "znamka" => :grade,
        "student_absent" => :absence,
        "ospravedlnenka" => :absence_note,
        "substitution" => :substitution,
        "timetable" => :timetable,
        "stravamenu" => :canteen_menu,
        "payments" => :payments,
        "signin" => :signin,
        "event" => :event,
        "ucivo" => :curriculum,
        "h_testvysledok" => :test_result,
        "testpridelenie" => :test_assignment
      }.freeze

      attribute :id, "timelineid"
      attribute :raw_type, "typ"
      attribute :text
      attribute :recipient_user_string, "user"
      attribute :recipient_name, "user_meno"
      attribute :owner_user_string, "vlastnik"
      attribute :owner_name, "vlastnik_meno"
      attribute :created_at, "cas_pridania", cast: :time
      attribute :occurred_at, "cas_udalosti", cast: :time
      attribute :reply_to_id, "reakcia_na"
      attribute :reply_count, "pocet_reakcii", cast: :integer
      attribute :removed, "removed", cast: :boolean
      attribute :other_id, "ineid"

      alias removed? removed

      attr_reader :student

      def initialize(data, school: nil, student: nil)
        super(data, school: school)
        @student = student
      end

      # A friendly symbol where one exists, otherwise the raw Edupage string.
      def type = TYPES.fetch(raw_type) { raw_type }

      def reply? = !reply_to_id.nil? && !reply_to_id.to_s.empty?

      # The embedded JSON document, or an empty hash.
      def payload
        @payload ||= begin
          raw = data["data"]
          parsed = raw.is_a?(String) ? (JSON.parse(raw) rescue nil) : raw
          parsed.is_a?(Hash) ? parsed : {}
        end
      end

      def owner
        @owner ||= school&.resolve_user_string(owner_user_string)
      end

      def recipient
        @recipient ||= school&.resolve_user_string(recipient_user_string)
      end

      def title = payload["nazov"].to_s.empty? ? nil : payload["nazov"]

      def name = title || text
      def match_strings = [id, title, text, raw_type].compact.map(&:to_s).reject(&:empty?)

      def to_s
        label = [title, text].compact.map { |s| s.to_s.gsub(/\s+/, " ") }.reject(&:empty?).first
        "#{created_at&.strftime("%Y-%m-%d %H:%M")} [#{type}] #{label}"
      end

      def to_h
        super.merge(type: type, title: title, payload_keys: payload.keys).compact
      end
    end
  end
end
