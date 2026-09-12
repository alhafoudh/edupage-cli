RSpec.describe Edupage::Session do
  subject(:session) do
    described_class.new(origin: "zsdemo", username: "u@example.com", credentials: credentials,
                        userid: "Rodic-1", role: "Rodic", store: store, client: client)
  end

  let(:credentials) { instance_double(Edupage::Credentials, password: "hunter2") }
  let(:store) { Edupage::SessionStore.new(path: File.join(Edupage::Config.cache_dir, "sessions.json")) }
  let(:client) { FakeClient.new }

  # Records every call and answers from a queue, so cursor traffic can be asserted.
  class FakeClient
    Response = Edupage::Client::Response

    attr_reader :calls
    attr_accessor :session_id

    def initialize
      @calls = []
      @responses = Hash.new { |h, k| h[k] = [] }
      @default = Response.new(status: 200, body: "{}", uri: "/")
    end

    # Replaces any queue already set for the path, so an example can override the
    # defaults its `before` block installed.
    def on(path, *responses) = @responses[path] = responses

    def get(path)
      @calls << [:get, path]
      next_response(path)
    end

    def post(path, data = {})
      @calls << [:post, path, data]
      next_response(path)
    end

    def paths = @calls.map { |c| c[1] }

    private

    def next_response(path)
      key = @responses.keys.find { |k| path.start_with?(k) }
      queued = key && @responses[key]
      queued && !queued.empty? ? queued.shift : @default
    end
  end

  def ok(body) = FakeClient::Response.new(status: 200, body: body, uri: "/")
  def redirect_to_login = FakeClient::Response.new(status: 302, body: "", uri: "/login/?eqa=x")

  describe "#with_cursor" do
    before do
      client.on("/login/switchchild", ok("OK"), ok("OK"), ok("OK"))
      client.on("/znamky/?what=setyear", ok("2025"), ok("2026"), ok("2025"))
    end

    it "pins both cursors before yielding" do
      session.with_cursor(child: 113_506, year: 2025) do
        expect(session.current_child).to eq("113506")
        expect(session.current_year).to eq("2025")
      end

      expect(client.paths).to include("/login/switchchild?studentid=113506", "/znamky/?what=setyear")
    end

    it "skips a switch that is already in effect" do
      session.with_cursor(child: 113_506, year: 2025) do
        session.with_cursor(child: 113_506, year: 2025) { :inner }
      end

      expect(client.calls.count { |c| c[1].start_with?("/login/switchchild") }).to eq(1)
      expect(client.calls.count { |c| c[1] == "/znamky/?what=setyear" }).to eq(1)
    end

    it "forgets the cursors once the lock is released" do
      # Another process can move them while we do not hold the lock, so anything we
      # believed about them has to expire with it.
      session.with_cursor(child: 113_506, year: 2025) { :ok }

      expect(session.current_child).to be_nil
      expect(session.current_year).to be_nil
    end

    it "refuses to yield when Edupage selects a different year" do
      client.on("/znamky/?what=setyear", ok("2026"))

      expect { session.with_cursor(year: 2025) { :never } }
        .to raise_error(Edupage::Error, /selected year 2026 instead of 2025/)
    end

    it "refuses to yield when the child switch fails" do
      client.on("/login/switchchild", ok("NOT OK"))

      expect { session.with_cursor(child: 1) { :never } }
        .to raise_error(Edupage::Error, /Failed to switch to child/)
    end
  end

  describe "expired sessions" do
    it "logs in again and retries the request once" do
      client.on("/user/", redirect_to_login, ok("<html>.userhome({});"))
      allow(Edupage::Client).to receive(:mauth).and_return(
        [{ userid: "Rodic-1", origin: "zsdemo", session_id: "fresh", role: "Rodic",
           first_name: "A", last_name: "B" }]
      )

      response = session.get("/user/")

      expect(response.body).to include("userhome")
      expect(client.session_id).to eq("fresh")
      expect(store.fetch("u@example.com", "zsdemo")[:session_id]).to eq("fresh")
    end

    it "gives up when the fresh session is rejected too" do
      client.on("/user/", redirect_to_login, redirect_to_login)
      allow(Edupage::Client).to receive(:mauth).and_return(
        [{ userid: "Rodic-1", origin: "zsdemo", session_id: "fresh", role: "Rodic" }]
      )

      expect { session.get("/user/") }.to raise_error(Edupage::SessionExpiredError)
    end

    it "reports when the account lost access to the school" do
      client.on("/user/", redirect_to_login)
      allow(Edupage::Client).to receive(:mauth).and_return(
        [{ userid: "Rodic-9", origin: "someotherschool", session_id: "x", role: "Rodic" }]
      )

      expect { session.get("/user/") }.to raise_error(Edupage::SessionExpiredError, /no longer has access/)
    end
  end

  it "detects a live session with a single cheap request" do
    client.on("/login/eauth", ok('{"status":"ok"}'))

    expect(session.valid?).to be(true)
  end

  it "detects a dead session" do
    client.on("/login/eauth", ok("notlogged"))

    expect(session.valid?).to be(false)
  end

  it "keeps the password out of inspect" do
    expect(session.inspect).not_to include("hunter2")
  end
end
