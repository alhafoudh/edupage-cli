module Edupage
  # A live connection to one Edupage school.
  #
  # Two things make this more than a cookie holder:
  #
  # 1. Re-login. Sessions expire server-side; any request can come back as a redirect
  #    to /login/. #request notices that, logs in again and retries once.
  #
  # 2. Cursors. Edupage keeps the "current child" and "current school year" in the
  #    session, not in the request, so asking for Jana's 2025 grades means mutating
  #    shared server state first. #with_cursor does that under a cross-process lock.
  class Session
    SWITCH_CHILD_PATH = "/login/switchchild".freeze
    SET_YEAR_PATH = "/znamky/?what=setyear".freeze
    PING_PATH = "/login/eauth?portalping".freeze

    attr_reader :origin, :username, :userid, :role, :name

    def initialize(origin:, username:, session_id: nil, credentials:, userid: nil, role: nil,
                   name: nil, store: SessionStore.new, client: nil)
      @origin = origin
      @username = username
      @credentials = credentials
      @store = store
      @userid = userid
      @role = role
      @name = name
      @client = client || Client.new(origin: origin, session_id: session_id)

      # Cursor state is only trustworthy while we hold the lock, since another process
      # sharing this session can switch it at any time. #release_lock clears it.
      @cursor = { child: nil, year: nil }
      @lock_depth = 0
    end

    def session_id = @client.session_id

    def get(path) = request(:get, path)
    def post(path, data = {}) = request(:post, path, data)

    def parent? = role.to_s.downcase.start_with?("rodic")

    # Cheap liveness check: 49 bytes, versus 375 KB for /user/.
    def valid?
      !@client.post(PING_PATH, "gpids" => "").expired?
    end

    # Logs in again and persists the new session id.
    def refresh!
      users = Client.mauth(school: origin, username: username, password: @credentials.password)
      entry = users.find { |u| u[:origin] == origin }
      raise SessionExpiredError, "Account #{username} no longer has access to #{origin}" unless entry

      @client.session_id = entry[:session_id]
      @userid = entry[:userid]
      @role = entry[:role]
      @name = [entry[:first_name], entry[:last_name]].compact.join(" ")
      persist!
      # A fresh session starts with the server's own defaults, not ours.
      @cursor = { child: nil, year: nil }
      self
    end

    # Runs the block with the session pointing at the given child and/or school year.
    #
    # Holds an exclusive lock for the whole block - not just the switch - so a
    # concurrent process cannot move the cursor between our switch and our fetch, which
    # would silently return another child's or another year's data.
    #
    # Re-entrant: nested calls reuse the held lock and skip switches that are already
    # in effect.
    def with_cursor(child: nil, year: nil)
      with_lock do
        # Setting the second cursor can trigger a re-login, which resets the first one
        # server-side. Re-apply until both actually hold before handing over control.
        2.times do
          set_child(child) if child
          set_year(year) if year
          break if cursors_match?(child, year)
        end

        unless cursors_match?(child, year)
          raise Error, "Could not pin session #{origin} to child=#{child.inspect} year=#{year.inspect}"
        end

        yield self
      end
    end

    def current_child = @cursor[:child]
    def current_year = @cursor[:year]

    def persist!
      @store.store(username, origin, session_id: session_id, userid: userid, role: role, name: name)
    end

    def inspect
      "#<Edupage::Session origin=#{origin.inspect} username=#{username.inspect} role=#{role.inspect}>"
    end

    private

    def cursors_match?(child, year)
      (child.nil? || @cursor[:child] == child.to_s) &&
        (year.nil? || @cursor[:year] == year.to_s)
    end

    def with_lock(&block)
      return yield if @lock_depth.positive?

      @store.with_lock do
        @lock_depth += 1
        begin
          block.call
        ensure
          @lock_depth -= 1
          # Outside the lock another process may move the cursors, so what we knew
          # about them expires with the lock.
          @cursor = { child: nil, year: nil } if @lock_depth.zero?
        end
      end
    end

    def set_child(student_id)
      id = student_id.to_s
      return if @cursor[:child] == id

      response = get("#{SWITCH_CHILD_PATH}?studentid=#{id}")
      unless response.ok? && response.body.to_s.strip.start_with?("OK")
        raise Error, "Failed to switch to child #{id} (HTTP #{response.status})"
      end

      @cursor[:child] = id
    end

    def set_year(year_id)
      id = year_id.to_s
      return if @cursor[:year] == id

      response = post(SET_YEAR_PATH, "znamky_yearid" => id)
      # The endpoint echoes the year it actually selected. That echo is the only
      # trustworthy confirmation: /user/ reports the new selectedYear immediately most
      # of the time, but occasionally lags a request behind (Edupage runs several app
      # servers and the dashboard appears to be cached per server). Consumers that care
      # about the year of a document - /user/ carries year-dependent dbi - must check
      # it themselves and refetch; see School#document.
      selected = response.body.to_s.strip.delete('"')
      raise Error, "Failed to switch to year #{id} (HTTP #{response.status})" unless response.ok?
      raise Error, "Edupage selected year #{selected} instead of #{id}" unless selected == id

      @cursor[:year] = selected
    end

    def request(method, path, data = nil, retried: false)
      response = data.nil? ? @client.get(path) : @client.post(path, data)
      return response unless response.expired?

      raise SessionExpiredError, "Session for #{origin} expired and re-login did not help" if retried

      Edupage.logger.debug("Session for #{origin} expired, logging in again")
      refresh!
      request(method, path, data, retried: true)
    end
  end
end
