module Edupage
  # The logged-in person, and the entry point to everything else.
  #
  # One set of credentials can reach several schools - a parent with children at two
  # schools gets two entries from a single login, each with its own session - so an
  # account owns a list of schools rather than being tied to one.
  class Account
    class << self
      # Reuses stored sessions when they are still alive and only logs in when needed.
      def login(username: nil, school: nil, credentials: nil, store: SessionStore.new, cache: nil)
        credentials ||= Credentials.new(username: username, school: school)
        username = credentials.username

        sessions = restore(username, credentials, store)
        sessions = authenticate(credentials, store) if sessions.empty?

        new(username: username, sessions: sessions, credentials: credentials,
            store: store, cache: cache)
      end

      private

      def restore(username, credentials, store)
        store.all(username).filter_map do |origin, entry|
          session = Session.new(
            origin: origin, username: username, session_id: entry[:session_id],
            credentials: credentials, userid: entry[:userid], role: entry[:role],
            name: entry[:name], store: store
          )
          session if session.valid?
        end
      end

      def authenticate(credentials, store)
        anchor = credentials.school
        unless anchor
          raise MissingCredentialsError,
                "No school to log in against. Pass --school, set EDUPAGE_SCHOOL, or set default_school."
        end

        Client.mauth(school: anchor, username: credentials.username, password: credentials.password)
              .map do |entry|
          Session.new(
            origin: entry[:origin], username: credentials.username, session_id: entry[:session_id],
            credentials: credentials, userid: entry[:userid], role: entry[:role],
            name: [entry[:first_name], entry[:last_name]].compact.join(" "), store: store
          ).tap(&:persist!)
        end
      end
    end

    attr_reader :username, :credentials

    def initialize(username:, sessions:, credentials:, store: SessionStore.new, cache: nil)
      @username = username
      @sessions = sessions
      @credentials = credentials
      @store = store
      @cache = cache
    end

    def schools
      @schools ||= Relation.wrap(@sessions.map { |session| School.new(session, cache: cache) })
    end

    def cache = @cache ||= Cache.new

    # One school is taken silently; several without a choice is refused.
    #
    # The config's default_school is not consulted here on purpose - it says where to log
    # in, not which school's data to read. See Registry::Context.
    def school(origin = nil)
      if origin.nil?
        raise AmbiguousScopeError.new(:school, school_candidates) if schools.count > 1

        return schools.first || raise(NotFoundError, "#{username} has access to no schools")
      end

      schools.find { |school| school.matches?(origin) } or
        raise NotFoundError,
              "No school #{origin.inspect} for #{username}. Available: #{schools.map(&:origin).join(", ")}"
    end

    def school_candidates
      schools.map { |school| { id: school.origin, label: school.name } }
    end

    # Taken from the login rather than any school page, so it works before any fetch.
    def name = @sessions.map(&:name).compact.reject(&:empty?).first

    def to_h
      { username: username, name: name, schools: schools.map(&:origin) }
    end

    # Forgets the stored sessions. The keychain password is untouched.
    def logout!
      @store.delete(username)
    end

    def inspect = "#<Edupage::Account #{username.inspect} schools=#{@sessions.map(&:origin).inspect}>"
  end
end
