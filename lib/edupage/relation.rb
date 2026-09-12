module Edupage
  # Lazy, chainable collection.
  #
  # Nothing is fetched until the relation is enumerated, so `student.homeworks` costs
  # nothing and `student.homeworks.where(...).first` fetches once. Filters are applied
  # in Ruby because Edupage has no query interface - the payload always arrives whole.
  class Relation
    include Enumerable

    def initialize(loader = nil, records: nil)
      @loader = loader
      @records = records
      @conditions = []
      @order = []
      @limit_value = nil
      @offset_value = 0
    end

    def self.wrap(records) = new(records: Array(records))

    def each(&block) = resolved.each(&block)

    # Conditions are ANDed. Values may be:
    #   exact      where(short: "MAT")        - case-insensitive
    #   regexp     where(name: /Jana/)
    #   range      where(due: Date.today..)
    #   array      where(type: %i[hw test])   - any of
    #   model      where(subject: subject)
    #   predicate  where(due: ->(d) { d.monday? })
    def where(**conditions)
      chain { |copy| copy.conditions.concat(conditions.to_a) }
    end

    # order(:due) or order(due: :desc) or order(:subject, :due)
    def order(*keys, **directions)
      pairs = keys.map { |k| [k, :asc] } + directions.to_a
      chain { |copy| copy.order_keys.concat(pairs) }
    end

    def limit(count) = chain { |copy| copy.limit_value = count }
    def offset(count) = chain { |copy| copy.offset_value = count }

    def find_by(**conditions) = where(**conditions).first

    # find(id) looks a record up by id, like ActiveRecord. With a block it stays
    # Enumerable#find, so `relation.find { |r| ... }` keeps working.
    def find(id = nil, &block)
      return super(&block) if block

      resolved.find { |record| record.respond_to?(:id) && record.id.to_s == id.to_s }
    end

    def first(count = nil) = count ? resolved.first(count) : resolved.first
    def last(count = nil) = count ? resolved.last(count) : resolved.last
    # count, count(value) and count { ... } all behave as Enumerable defines them;
    # the bare form is the common "how many records" case.
    def count(*args, &block)
      return resolved.size if args.empty? && block.nil?

      resolved.count(*args, &block)
    end

    def size = resolved.size
    def empty? = resolved.empty?
    def to_a = resolved.dup
    def to_ary = to_a

    def inspect
      "#<Edupage::Relation #{loaded? ? "#{resolved.size} records" : "not loaded"}>"
    end

    def loaded? = !@resolved.nil?

    protected

    attr_accessor :limit_value, :offset_value
    attr_reader :conditions

    def order_keys = @order

    def initialize_copy(source)
      super
      @conditions = source.conditions.dup
      @order = source.order_keys.dup
      @resolved = nil
    end

    private

    def chain
      copy = dup
      yield copy
      copy
    end

    def resolved
      @resolved ||= begin
        records = @records || Array(@loader.call)
        records = records.select { |record| matches_all?(record) } unless @conditions.empty?
        records = sort(records) unless @order.empty?
        records = records.drop(@offset_value || 0)
        limit = @limit_value
        limit ? records.first(limit) : records
      end
    end

    def matches_all?(record)
      @conditions.all? { |key, query| matches?(record, key, query) }
    end

    # `name` is the one filter that searches the record rather than a single attribute:
    # asking for a subject by "MAT" should find "Matematika", and a teacher by their
    # short code should find them too. Every other key compares its attribute directly.
    NAME_KEY = :name

    def matches?(record, key, query)
      return true if query.nil?

      if key == NAME_KEY && record.respond_to?(:match_strings)
        return Array(query).any? { |q| record.matches?(q) } if query.is_a?(Array)

        return record.matches?(query)
      end

      return false unless record.respond_to?(key)

      value = record.public_send(key)

      case query
      when Proc then query.call(value)
      when Array then query.any? { |q| matches_value?(value, q) }
      else matches_value?(value, query)
      end
    end

    def matches_value?(value, query)
      case query
      when Range then !value.nil? && query.cover?(value)
      when Regexp then matchable(value).any? { |candidate| candidate.match?(query) }
      else
        # Delegating to the model lets `where(subject: "MAT")` hit either the short
        # code or the full name without the caller knowing which.
        return value.matches?(query) if value.is_a?(Model)
        return value == query if query.is_a?(Model)

        matchable(value).any? { |candidate| candidate.casecmp?(query.to_s) }
      end
    end

    def matchable(value)
      case value
      when Model then value.match_strings
      when Array then value.flat_map { |v| matchable(v) }
      when nil then []
      else [value.to_s]
      end
    end

    def sort(records)
      records.sort do |a, b|
        @order.reduce(0) do |result, (key, direction)|
          next result unless result.zero?

          comparison = compare(read(a, key), read(b, key))
          direction.to_sym == :desc ? -comparison : comparison
        end
      end
    end

    def read(record, key) = record.respond_to?(key) ? record.public_send(key) : nil

    # nil sorts last, so an unset due date does not lead the list.
    def compare(left, right)
      return 0 if left.nil? && right.nil?
      return 1 if left.nil?
      return -1 if right.nil?

      # Models sort by their display name; mixed types fall back to string order.
      left = left.name.to_s if left.is_a?(Model)
      right = right.name.to_s if right.is_a?(Model)

      (left <=> right) || (left.to_s <=> right.to_s)
    end
  end
end
