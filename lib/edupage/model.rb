require "date"
require "time"

module Edupage
  # Base for every value object parsed out of an Edupage payload.
  #
  # Models are thin wrappers over the raw hash Edupage sent. The `attribute` DSL maps
  # Edupage's Slovak/abbreviated keys onto Ruby names and casts once, in one place,
  # instead of scattering `data["numberinclass"].to_i` through the codebase. The raw
  # hash stays reachable via #data for the fields nobody has modelled yet.
  class Model
    CASTS = {
      string: ->(v) { v.nil? ? nil : v.to_s },
      integer: ->(v) { v.nil? || v.to_s.empty? ? nil : Integer(v, exception: false) },
      float: ->(v) { v.nil? || v.to_s.empty? ? nil : Float(v, exception: false) },
      boolean: ->(v) { [true, "1", 1, "true"].include?(v) },
      date: ->(v) { parse_date(v) },
      time: ->(v) { parse_time(v) },
      raw: ->(v) { v }
    }.freeze

    class << self
      def attributes = @attributes ||= superclass.respond_to?(:attributes) ? superclass.attributes.dup : {}

      # Declares a reader backed by +key+ in the raw payload.
      #
      #   attribute :first_name, "firstname"
      #   attribute :number, "numberinclass", cast: :integer
      #
      # A block receives the raw hash for values that need assembling rather than
      # looking up.
      def attribute(name, key = name.to_s, cast: nil, &block)
        # A block usually assembles an object (a Subject, a list of Teachers), so it
        # defaults to no cast; a plain key lookup defaults to a string.
        cast ||= block ? :raw : :string
        attributes[name.to_sym] = { key: key.to_s, cast: cast, block: block }

        define_method(name) do
          @computed.fetch(name) { @computed[name] = read_attribute(name) }
        end
      end

      def parse_date(value)
        return value if value.is_a?(Date) && !value.is_a?(DateTime)
        return nil if value.nil? || value.to_s.empty?

        Date.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil? || value.to_s.empty?

        # Edupage sends local wall-clock timestamps with no zone.
        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end

    attr_reader :data, :school

    def initialize(data, school: nil)
      @data = data || {}
      @school = school
      @computed = {}
    end

    # Most Edupage records key off one of these.
    def id
      @id ||= (data["id"] || data["studentid"] || data["ucitelid"] || data["classid"]).then do |value|
        value.nil? ? nil : value.to_s
      end
    end

    def name = respond_to?(:full_name) ? full_name : data["name"]

    # Strings a human might use to refer to this record on the command line.
    # `where(subject: "MAT")` should match the short code as readily as the full name.
    def match_strings
      [id, (name if respond_to?(:name)), (short if respond_to?(:short))]
        .compact.map(&:to_s).reject(&:empty?)
    end

    def matches?(query)
      return true if query.nil?

      case query
      when Model then id == query.id
      when Regexp then match_strings.any? { |candidate| candidate.match?(query) }
      else match_strings.any? { |candidate| candidate.casecmp?(query.to_s) }
      end
    end

    def to_h
      self.class.attributes.keys.to_h { |name| [name, serialize(public_send(name))] }
                          .merge(id: id).compact
    end

    def ==(other) = other.is_a?(self.class) && !id.nil? && id == other.id
    alias eql? ==

    def hash = [self.class, id].hash

    def inspect
      shown = self.class.attributes.keys.first(4)
                  .to_h { |a| [a, public_send(a)] }.compact
                  .map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      "#<#{self.class.name.split("::").last} id=#{id.inspect} #{shown}>"
    end

    private

    def read_attribute(name)
      spec = self.class.attributes.fetch(name)
      raw = spec[:block] ? instance_exec(data, &spec[:block]) : data[spec[:key]]
      CASTS.fetch(spec[:cast]).call(raw)
    end

    def serialize(value)
      case value
      when Model then value.id
      when Array then value.map { |v| serialize(v) }
      when Date, Time then value.iso8601
      else value
      end
    end
  end
end
