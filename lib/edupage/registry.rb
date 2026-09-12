module Edupage
  # The single description of what this tool can read.
  #
  # The library is hand-written and idiomatic; the CLI, the REST API and the MCP server
  # are all generated from the declarations here. Nothing about a resource - its name,
  # its filters, their types, what it returns - is written down more than once, so the
  # three surfaces cannot drift apart. spec/registry_parity_spec.rb enforces that.
  #
  #   Registry.resource :grades do
  #     scope   :year
  #     summary "Grades for a school year"
  #     param   :term, type: :enum, values: %w[P1 P2], desc: "Half-year"
  #     resolve ->(year, p) { year.grades.where(term: p[:term]) }
  #   end
  class Registry
    # Which session cursors a resource needs, and therefore which object resolves it.
    #
    # The scopes nest: a year implies a student, a student implies a school. Surfaces
    # read this to build their own shape - URL segments for REST, options for the CLI,
    # input schema properties for MCP - so a resource can never be wired up to one
    # surface and forgotten in another.
    # `chain` is the levels a resource actually stands on; `params` additionally carries
    # the optional year filter that school- and student-scoped resources accept. The two
    # differ on purpose: `students` takes `--year` to pick which year's directory to
    # read, but it is not a year-scoped resource and must never require a student.
    SCOPES = {
      account: { receiver: :account, chain: [], params: [] },
      school: { receiver: :school, chain: %i[school], params: %i[school year] },
      student: { receiver: :student, chain: %i[school student], params: %i[school student year] },
      year: { receiver: :year, chain: %i[school student year], params: %i[school student year] }
    }.freeze

    # Parameters implied by the scope rather than declared by the resource.
    #
    # school and student are required wherever they apply: no level of the chain may be
    # skipped, and a caller that omits one is told what it could have chosen. The year is
    # the exception - "now" is unambiguous, so it defaults to the current year and the
    # CLI shows which one it used.
    SCOPE_PARAMS = {
      school: { type: :string, desc: "School origin, e.g. zsdemo", required: true },
      student: { type: :string, desc: "Student name or id", required: true },
      year: { type: :string, desc: "School year, e.g. 2025 (defaults to the current one)",
              required: false }
    }.freeze

    Param = Struct.new(:name, :type, :desc, :values, :required, keyword_init: true) do
      def enum? = type == :enum

      def json_schema
        base = case type
               when :integer then { "type" => "integer" }
               when :boolean then { "type" => "boolean" }
               when :date then { "type" => "string", "format" => "date" }
               else { "type" => "string" }
               end
        base["enum"] = values if enum? && values
        base["description"] = desc if desc
        base
      end
    end

    # One readable thing, described once.
    class Resource
      attr_reader :name

      def initialize(name)
        @name = name.to_sym
        @scope = :account
        @summary = nil
        @params = {}
        @table_fields = []
        @resolver = nil
      end

      # --- DSL ----------------------------------------------------------------------

      def scope(value = nil)
        return @scope if value.nil?

        unless SCOPES.key?(value)
          raise ArgumentError, "Unknown scope #{value.inspect}; expected one of #{SCOPES.keys.inspect}"
        end

        @scope = value
      end

      def summary(value = nil)
        value.nil? ? @summary : (@summary = value)
      end

      def param(name, type: :string, desc: nil, values: nil, required: false)
        @params[name.to_sym] = Param.new(name: name.to_sym, type: type, desc: desc,
                                         values: values, required: required)
      end

      def table_fields(*fields)
        fields.empty? ? @table_fields : (@table_fields = fields.flatten.map(&:to_sym))
      end

      def resolve(callable = nil, &block)
        @resolver = callable || block
      end

      # --- reading ------------------------------------------------------------------

      def own_params = @params.values

      # Scope parameters first, then the resource's own filters.
      def all_params
        scope_params + own_params
      end

      def scope_params
        SCOPES.fetch(@scope)[:params].map do |key|
          Param.new(name: key, **SCOPE_PARAMS.fetch(key))
        end
      end

      def receiver_kind = SCOPES.fetch(@scope)[:receiver]

      # Levels of the chain this resource actually stands on, outermost first. Surfaces
      # use it to show which school, student and year an answer came from.
      def scope_chain = SCOPES.fetch(@scope)[:chain]

      def singular? = @table_fields.empty? && name.to_s.end_with?("account")

      # REST path, derived from the scope so it cannot disagree with the CLI or MCP.
      def rest_path
        case @scope
        when :account then "/api/v1/#{name}"
        when :school then "/api/v1/schools/:school/#{name}"
        when :student then "/api/v1/schools/:school/students/:student/#{name}"
        when :year then "/api/v1/schools/:school/students/:student/years/:year/#{name}"
        end
      end

      def tool_name = "edupage_#{name}"

      def call(context, params = {})
        raise Error, "Resource #{name} has no resolver" unless @resolver

        @resolver.call(context.receiver_for(self), normalize(params))
      end

      # Drops unknown keys and blank values so surfaces can pass their raw input.
      def normalize(params)
        known = all_params.map(&:name)
        params.to_h.each_with_object({}) do |(key, value), result|
          key = key.to_sym
          next unless known.include?(key)
          next if value.nil? || value.to_s.empty?

          result[key] = cast(key, value)
        end
      end

      def validate!
        raise ArgumentError, "Resource #{name} needs a summary" if @summary.nil?
        raise ArgumentError, "Resource #{name} needs a resolver" if @resolver.nil?

        self
      end

      private

      def cast(key, value)
        param = all_params.find { |p| p.name == key }
        case param&.type
        when :integer then Integer(value, exception: false) || value
        when :boolean then [true, "true", "1", 1].include?(value)
        when :date then value.is_a?(Date) ? value : (Date.parse(value.to_s) rescue value)
        else value
        end
      end
    end

    # Resolves the object a resource should be called on, from surface-level strings.
    #
    # This is where "--student Jana" or ".../students/113506/..." becomes a Student,
    # once, for every surface.
    class Context
      def initialize(account:, school: nil, student: nil, year: nil)
        @account = account
        @school_ref = school
        @student_ref = student
        @year_ref = year
      end

      def account = @account

      # Each level resolves the same way: an explicit choice wins, a single option is
      # taken silently, and anything else is refused rather than guessed.
      #
      # Config defaults deliberately do not count as a choice. `default_school` is the
      # login anchor - which *.edupage.org host to authenticate against - and letting it
      # also decide which school's data you are reading is how you end up looking at the
      # wrong child's school without noticing.
      def school
        @school ||= @account.school(@school_ref)
      end

      def student
        @student ||= begin
          ref = @student_ref
          candidates = school.students

          if ref.nil?
            raise AmbiguousScopeError.new(:student, student_candidates(candidates)) if candidates.count > 1

            candidates.first or raise NotFoundError, "#{school.origin} has no students for this account"
          else
            resolve_student(ref, candidates) or
              raise NotFoundError, "No student #{ref.inspect}. Available: #{candidates.map(&:full_name).join(", ")}"
          end
        end
      end

      def year
        @year ||= explicit_year? ? student.year(@year_ref) : student.current_year
      end

      # Whether the year came from the caller or was filled in as "now". The CLI says so
      # in its output, because in September the current year is usually empty and the
      # interesting data is in the previous one.
      def year_defaulted? = !explicit_year?

      def explicit_year?
        !@year_ref.nil? && @year_ref.to_s != "current"
      end

      def receiver_for(resource)
        public_send(resource.receiver_kind)
      end

      private

      # Exact match on id or full name first, then a unique partial name match, so
      # "--student Jana" works without typing the surname. An ambiguous prefix is an
      # error rather than an arbitrary pick.
      def resolve_student(ref, candidates)
        exact = candidates.find { |student| student.matches?(ref) }
        return exact if exact

        needle = ref.to_s.downcase
        partial = candidates.select { |student| student.full_name.downcase.include?(needle) }
        return partial.first if partial.size == 1

        if partial.size > 1
          raise NotFoundError,
                "#{ref.inspect} matches several students: #{partial.map(&:full_name).join(", ")}"
        end

        nil
      end

      def student_candidates(students)
        students.map do |student|
          { id: student.id, label: [student.full_name, student.class_name].compact.join(", ") }
        end
      end
    end

    class << self
      def resources = @resources ||= {}

      def resource(name, &block)
        entry = Resource.new(name)
        entry.instance_eval(&block)
        resources[entry.name] = entry.validate!
      end

      def [](name) = resources[name.to_sym]
      def all = resources.values
      def names = resources.keys
      def each(&block) = all.each(&block)

      def fetch(name)
        self[name] or raise NotFoundError, "Unknown resource #{name.inspect}; known: #{names.join(", ")}"
      end
    end
  end
end

# Declarations reopen Registry rather than defining a constant of their own, so they sit
# outside Zeitwerk's file-to-constant mapping and are loaded here instead.
require_relative "registry/resources"
