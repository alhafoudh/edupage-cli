# A Session that answers from canned payloads instead of the network.
#
# It honours the cursors for real - switching child or year changes what the pages
# return - so the settling logic in School is exercised rather than bypassed.
class FakeSession
  Response = Edupage::Client::Response

  attr_reader :origin, :username, :role, :name, :userid, :requests
  attr_accessor :child, :year, :lag

  def initialize(origin: "zsdemo", role: "Rodic", year: "2026", child: "113506", lag: 0)
    @origin = origin
    @username = "parent@example.com"
    @role = role
    @userid = "Rodic-1"
    @name = "Ahmed Novák"
    @child = child
    @year = year
    @requests = []
    # How many requests the pages trail a cursor switch by, as the real server does.
    @lag = lag
    @pending = nil
  end

  def parent? = role.to_s.downcase.start_with?("rodic")
  def valid? = true
  def session_id = "fake"
  def persist! = true

  def with_cursor(child: nil, year: nil)
    apply(:child, child) if child
    apply(:year, year) if year
    yield self
  end

  def get(path)
    @requests << path
    settle_lag

    case path
    when %r{\A/znamky/} then ok(znamky_html(path))
    when %r{\A/user/} then ok(Payloads.userhome_html(child: @child, year: @year))
    when %r{eb\.php} then ok(%(<div gpid="123"></div>))
    else ok("")
    end
  end

  def post(path, _data = {})
    @requests << path
    ok("")
  end

  private

  # Mimics the server: the switch is acknowledged at once but the pages catch up only
  # after `lag` more requests. Re-sending the same switch does not restart the
  # countdown, just as repeating it against the real server does not.
  def apply(cursor, value)
    value = value.to_s
    return if public_send(cursor) == value
    return if @pending && @pending[0] == cursor && @pending[1] == value

    if @lag.zero?
      public_send(:"#{cursor}=", value)
    else
      @pending = [cursor, value, @lag]
    end
  end

  def settle_lag
    return unless @pending

    cursor, value, remaining = @pending
    if remaining <= 1
      public_send(:"#{cursor}=", value)
      @pending = nil
    else
      @pending = [cursor, value, remaining - 1]
    end
  end

  def znamky_html(path)
    term = path[/nadobdobie=(\w+)/, 1] || "P2"
    Payloads.znamky_html(year: @year, term: term)
  end

  def ok(body) = Response.new(status: 200, body: body, uri: "/")
end

module SchoolHelpers
  def fake_school(**options)
    Edupage::School.new(FakeSession.new(**options), cache: Edupage::Cache.new(enabled: false))
  end
end

RSpec.configure { |config| config.include(SchoolHelpers) }
