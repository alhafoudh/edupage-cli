module Edupage
  # One school reachable by the account, and the owner of everything fetched from it.
  #
  # Fetching is centralised here for two reasons:
  #
  # * /user/ is one 375 KB request that backs roughly ten different collections, so it
  #   is fetched once per (child, year) and shared.
  # * The child and year cursors live in the session, so every fetch has to be wrapped
  #   in Session#with_cursor. Doing that in one place keeps models from having to know
  #   about it.
  class School
    USER_PATH = "/user/".freeze

    attr_reader :session, :cache

    def initialize(session, cache: Cache.new)
      @session = session
      @cache = cache
      @documents = {}
    end

    def origin = session.origin
    def role = session.role
    def parent? = session.parent?
    def name = document.school_name
    def id = origin
    def short = origin

    def match_strings = [origin, name].compact
    def matches?(query)
      return true if query.nil?

      case query
      when Regexp then match_strings.any? { |c| c.match?(query) }
      else match_strings.any? { |c| c.casecmp?(query.to_s) }
      end
    end

    # --- school directory -----------------------------------------------------------

    def students(year: nil)
      scope = parent? ? own_children(year: year) : build(Models::Student, "students", year: year)
      Relation.wrap(scope)
    end

    def teachers(year: nil) = Relation.wrap(build(Models::Teacher, "teachers", year: year))
    def parents(year: nil) = Relation.wrap(build(Models::Parent, "parents", year: year))
    def classes(year: nil) = Relation.wrap(build(Models::SchoolClass, "classes", year: year))
    def classrooms(year: nil) = Relation.wrap(build(Models::Classroom, "classrooms", year: year))
    def subjects(year: nil) = Relation.wrap(build(Models::Subject, "subjects", year: year))
    def periods(year: nil) = Relation.wrap(build(Models::Period, "periods", year: year))

    # id lookups, memoized per year so resolving a lesson's teacher is not O(n) each time
    # Looks through every pupil, not only a parent's own children, because timeline
    # items and grades can reference classmates.
    def student(id)
      return nil if id.nil? || id.to_s.empty?

      (@student_index ||= all_students.to_h { |s| [s.id, s] })[id.to_s]
    end

    def teacher(id) = lookup(:teachers, id)
    def parent(id) = lookup(:parents, id)
    def school_class(id) = lookup(:classes, id)
    def classroom(id) = lookup(:classrooms, id)
    def subject(id) = lookup(:subjects, id)
    def period(id) = lookup(:periods, id)

    # --- years ----------------------------------------------------------------------

    # The real current school year, regardless of where the session cursor happens to
    # be pointing.
    def current_year
      @current_year ||= begin
        # Bootstrap: the year cursor is shared and persists across processes, so a
        # previous command may have left it in the past. Read the page once without
        # pinning anything, take autoYear from it - that value ignores the cursor - and
        # keep the document if it happens to already be the right year.
        doc = fetch_document(child: nil, year: nil)
        @documents[[nil, doc.current_year]] ||= doc if doc.selected_year == doc.current_year
        doc.current_year
      end
    end

    # Every school year the student has data for, newest first.
    #
    # yearterms lists them all in one response, together with each term's date span and
    # grade count, so the listing needs exactly one fetch - pinned to the current year
    # so repeated runs agree. Asking Edupage about each year separately would be both
    # slower and unreliable: switching to a year the child was never enrolled in is
    # silently ignored, and the page trails the switch by a request or two.
    def years_for(student)
      @years ||= {}
      @years[student.id] ||= begin
        rows = znamky_for(student, year: current_year).year_terms
        names = rows.to_h { |row| [row["yearid"].to_s, row["yearName"]] }
        ids = (rows.map { |row| row["yearid"].to_s } + [current_year.to_s])
              .uniq.reject(&:empty?).sort.reverse

        Relation.wrap(
          ids.map do |id|
            Year.new(school: self, student: student, id: id, name: names[id],
                     current: id == current_year.to_s,
                     term_rows: rows.select { |row| row["yearid"].to_s == id })
          end
        )
      end
    end

    # The parsed grades page for a student, year and half-year.
    #
    # Child and year are session cursors; the half-year is a query parameter. Omitting
    # the term yields whichever half Edupage considers current, which is what the year
    # and term listings are read from.
    def znamky_for(student, year: nil, term: nil)
      year = (year || current_year).to_s
      key = [student.id, year, term&.to_s]

      (@znamky ||= {})[key] ||= settle({ year: year, student: student.id },
                                       "grades for #{student.full_name}") do
        parsed = fetch_znamky(student, year, term)
        [parsed, { year: parsed.year_id, student: parsed.student_id }]
      end
    end

    # --- timetable ------------------------------------------------------------------

    # range may be nil (today), a Date, or a Date range.
    def timetable_for(student, range = nil)
      case range
      when nil then day_for(student, Date.today)
      when Date then day_for(student, range)
      when Range then Relation.new(-> { days_for(student, range.first, range.last) })
      else raise ArgumentError, "Expected a Date or a Date range, got #{range.class}"
      end
    end

    def lessons_for(student, date = nil)
      day = timetable_for(student, date || Date.today)
      day ? day.lessons : Relation.wrap([])
    end

    # --- timeline and assignments ---------------------------------------------------

    # The whole feed, or just one student's share of it.
    #
    # For a parent the feed is shared across children, so one fetch serves everyone and
    # the split happens locally via childGroups.
    def timeline_for(student = nil)
      Relation.new(lambda {
        rows = student ? feed.for_student(student.id) : feed.items
        rows.map { |row| build_timeline_item(row, student) }
      })
    end

    def assignments_for(student = nil)
      Relation.new(lambda {
        rows = student ? feed.for_student(student.id) : feed.items
        rows.select { |row| Models::Assignment.assignment?(row) }
            .map { |row| Models::Assignment.new(row, school: self, student: student) }
      })
    end

    # Turns an Edupage userstring ("Student113506", "Ucitel37135", "Rodic-20079") into
    # the record it names, when we have one.
    def resolve_user_string(value)
      return nil if value.nil? || value.to_s.empty?

      match = value.to_s.match(/\A(Student|StudentOnly|Ucitel|Rodic)(-?\d+)\z/)
      return nil unless match

      case match[1]
      when "Student", "StudentOnly" then student(match[2])
      when "Ucitel" then teacher(match[2])
      when "Rodic" then parent(match[2])
      end
    end

    # --- fetching -------------------------------------------------------------------

    # The parsed /user/ document for a given child and year.
    #
    # Edupage usually applies a year switch immediately but occasionally serves a
    # dashboard from before it (several app servers, each with its own cache), so the
    # year the document reports is verified and the fetch retried once. Without this,
    # `school.year(2025).classes` can silently return this year's class list.
    def document(child: nil, year: nil)
      # Never fall back to whatever year the shared session was left on: pin it.
      year ||= current_year
      key = [child&.to_s, year&.to_s]

      # Both cursors are verified, not just the year: the dashboard trails a child
      # switch the same way, and an unverified fetch hands back one child's timetable
      # under the other child's name.
      @documents[key] ||= settle({ year: year, child: child }, "dashboard") do
        parsed = fetch_document(child: child, year: year)
        [parsed, { year: parsed.selected_year, child: parsed.logged_child }]
      end
    end

    def reload!
      @documents.clear
      @lookups = nil
      @built = nil
      @years = nil
      @znamky = nil
      @current_year = nil
      @feed = nil
      @student_index = nil
      self
    end

    def to_h
      { origin: origin, name: name, role: role, current_year: current_year }
    end

    def inspect = "#<Edupage::School #{origin.inspect} role=#{role.inspect}>"

    private

    # How many times to refetch while waiting for a year switch to show up.
    SETTLE_ATTEMPTS = 4

    # Refetches until the page reports the child and year that were asked for.
    #
    # Both cursor switches are acknowledged immediately but the pages trail them by one
    # or two requests. Serving that lagging page would be the worst possible outcome -
    # one child's timetable or last year's grades presented as the other's - so the
    # response is checked against what was requested and refused if it never catches up.
    #
    # A year the student was never enrolled in never takes effect at all, and surfaces
    # here as NotFoundError rather than as somebody else's data.
    def settle(expected, what)
      wanted = expected.compact.transform_values(&:to_s)
      return yield.first if wanted.empty?

      seen = nil

      SETTLE_ATTEMPTS.times do
        parsed, actual = yield
        actual = actual.transform_values { |v| v&.to_s }
        return parsed if wanted.all? { |key, value| actual[key] == value }

        seen = actual
        Edupage.logger.debug("#{origin}: #{what} came back as #{actual.inspect}, waiting for #{wanted.inspect}")
      end

      raise NotFoundError,
            "#{origin} never returned #{what} for #{describe(wanted)} " \
            "(it keeps answering with #{describe(seen)}). The student may not have been enrolled then."
    end

    def describe(values)
      return "nothing" if values.nil?

      values.map { |key, value| "#{key}=#{value}" }.join(" ")
    end

    def feed
      @feed ||= Parsers::Timeline.from_userhome(document)
    end

    # Assignment rows become Assignments; everything else stays a plain item.
    def build_timeline_item(row, student)
      klass = Models::Assignment.assignment?(row) ? Models::Assignment : Models::TimelineItem
      klass.new(row, school: self, student: student)
    end

    # Every pupil in the school, as opposed to #students which narrows to a parent's
    # own children.
    def all_students(year: nil)
      build(Models::Student, "students", year: year)
    end

    # Cached payloads are the parsed blobs rather than the raw HTML: a tenth of the
    # size, and no need to re-scan 375 KB on every read.
    def fetch_znamky(student, year, term)
      blob = cache.fetch(origin, year, student.id, "znamky-#{term || "current"}",
                         kind: :znamky, immutable: closed_year?(year)) do
        html = session.with_cursor(child: student.id, year: year) do |s|
          s.get(Parsers::Znamky.path_for(term: term)).body
        end
        parsed = Parsers::Znamky.parse(html)
        { "data" => parsed.data, "settings" => parsed.settings }
      end

      Parsers::Znamky.new(blob["data"], settings: blob["settings"] || {})
    end

    def fetch_document(child:, year:)
      blob = cache.fetch(origin, year, child || "default", "user",
                         kind: :document, immutable: closed_year?(year)) do
        html = session.with_cursor(child: child, year: year) { |s| s.get(USER_PATH).body }
        parsed = Parsers::Userhome.parse(html)
        { "data" => parsed.data, "edubar" => parsed.edubar, "asc" => parsed.asc }
      end

      Parsers::Userhome.new(blob["data"], edubar: blob["edubar"] || {}, asc: blob["asc"] || {})
    end

    # A year that has ended can no longer change, so its pages are cached indefinitely.
    def closed_year?(year)
      year && @current_year && year.to_s < @current_year.to_s
    end

    # For a parent account, `students` means the account's own children rather than
    # every pupil in the school.
    def own_children(year: nil)
      doc = document(year: year)
      ids = doc.parent_student_ids
      all = build(Models::Student, "students", year: year)
      return all if ids.empty?

      ids.filter_map { |id| all.find { |student| student.id == id } }
    end

    def build(model, collection, year: nil)
      cache_key = [model, collection, year&.to_s]
      (@built ||= {})[cache_key] ||=
        document(year: year).collection(collection).map { |row| model.new(row, school: self) }
    end

    # Lookups always use the currently loaded year: a lesson fetched for 2025 must
    # resolve its teacher against 2025's directory.
    def lookup(collection, id)
      return nil if id.nil? || id.to_s.empty?

      @lookups ||= {}
      @lookups[collection] ||= public_send(collection).to_h { |record| [record.id, record] }
      @lookups[collection][id.to_s]
    end

    def day_for(student, date)
      days_for(student, date, date).first
    end

    def days_for(student, from, to)
      doc = document(child: student.id)
      dates = doc.dates

      missing = (from..to).map(&:iso8601) - dates.keys
      dates = dates.merge(fetch_range(student, from, to)) unless missing.empty?

      (from..to).filter_map do |date|
        row = dates[date.iso8601]
        Models::Day.new(row, school: self, date: date) if row
      end
    end

    # /user/ only ever carries about four days; anything wider comes from /gcall.
    def fetch_range(student, from, to)
      cache.fetch(origin, current_year, student.id, "tt-#{from.iso8601}-#{to.iso8601}",
                  kind: :timetable) do
        Parsers::Gcall.new(self).load(student: student, from: from, to: to)
      end
    end
  end
end
