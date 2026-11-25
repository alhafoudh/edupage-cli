require "rack/test"

RSpec.describe "Public /mcp endpoint" do
  include Rack::Test::Methods

  let(:public_ns) { Edupage::Server::Public }
  let(:app) { public_ns::App }
  let(:now) { 1_000_000 }
  let(:clock) { -> { now } }
  let(:settings) do
    public_ns::Settings.new(public_url: "https://mcp.example.com", secret_key: "k" * 32,
                            data_dir: Edupage::Config.cache_dir)
  end
  let(:store) { public_ns::Store.new(File.join(Edupage::Config.cache_dir, "m.sqlite3")) }
  let(:grants) { public_ns::Grants.new(store: store, pepper: settings.pepper, clock: -> { clock.call }) }
  let(:builder) do
    lambda do |_grant_id, credentials|
      origin = credentials[:school]
      Edupage::Account.new(username: credentials[:username], sessions: [FakeSession.new(origin: origin)],
                           credentials: Edupage::StaticCredentials.new(username: credentials[:username],
                                                                       password: nil, school: origin),
                           cache: Edupage::Cache.new(enabled: false))
    end
  end
  let(:runtimes) { public_ns::Runtimes.new(data_dir: Edupage::Config.cache_dir, account_builder: builder) }
  let(:verifier) { "v" * 50 }

  before do
    app.configure_with(settings: settings, clients: public_ns::Clients.new(store: store), grants: grants,
                       flow: nil, pending: public_ns::Pending.new, runtimes: runtimes,
                       mcp: Edupage::Server::MCP.new(public: true))
    header "Host", "mcp.example.com"
    header "Accept", "application/json, text/event-stream"
    header "Content-Type", "application/json"
  end

  def connect(username, school, two_factor_origins: [])
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    credentials = { username: username, school: school, schools: [school], two_factor_origins: two_factor_origins,
                    sessions: { school => { session_id: "sid-#{school}", userid: "Rodic-1", role: "Rodic", name: "A B" } } }
    _, code = grants.issue_code(client_id: "c1", credentials: credentials, redirect_uri: "https://claude.ai/cb",
                                code_challenge: challenge, resource: settings.resource)
    grants.exchange_code(code, client_id: "c1", redirect_uri: "https://claude.ai/cb", code_verifier: verifier)
  end

  def rpc(token, method, params = {})
    header "Authorization", "Bearer #{token}" if token
    post "/mcp", JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params)
  end

  def call_tool(token, name, arguments = {})
    rpc(token, "tools/call", name: name, arguments: arguments)
    JSON.parse(last_response.body)
  end

  def tool_text(response) = response.dig("result", "content", 0, "text")

  it "answers with the token's own account only" do
    a = connect("parent-a", "zsdemo")
    connect("parent-b", "zsother")

    schools = JSON.parse(tool_text(call_tool(a.access_token, "edupage_schools")))
    expect(schools.map { |s| s["origin"] || s["id"] }.compact.join).to include("zsdemo")
    expect(schools.to_s).not_to include("zsother")
  end

  it "ignores username and refuses schools of other accounts" do
    a = connect("parent-a", "zsdemo")
    connect("parent-b", "zsother")

    response = call_tool(a.access_token, "edupage_students", "school" => "zsother", "username" => "parent-b")
    expect(response.dig("result", "isError")).to be(true)
    expect(tool_text(response)).to include("zsother")
    expect(tool_text(response)).not_to include("parent-b")
  end

  it "names the JSON-RPC method and tool for the access log, never the arguments" do
    a = connect("parent-a", "zsdemo")
    call_tool(a.access_token, "edupage_students", "school" => "zsdemo", "name" => "Jana")

    expect(last_request.env[public_ns::RequestLog::DETAIL]).to eq("tools/call edupage_students")
  end

  it "names plain methods too" do
    rpc(connect("parent-a", "zsdemo").access_token, "tools/list")

    expect(last_request.env[public_ns::RequestLog::DETAIL]).to eq("tools/list")
  end

  it "has no username argument in any tool" do
    rpc(connect("parent-a", "zsdemo").access_token, "tools/list")
    tools = JSON.parse(last_response.body).dig("result", "tools")

    expect(tools).not_to be_empty
    expect(tools.map { |t| t.dig("inputSchema", "properties")&.keys }.flatten.compact).not_to include("username")
  end

  it "tells the client to reconnect for a school whose two-factor was skipped" do
    a = connect("parent-a", "zsdemo", two_factor_origins: ["zsother"])

    response = call_tool(a.access_token, "edupage_students", "school" => "zsother")
    expect(response.dig("result", "isError")).to be(true)
    expect(tool_text(response)).to include("Odpoj a znova pripoj Edupage konektor")
  end

  describe "authentication" do
    let(:expected_header) do
      'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", ' \
        'error="invalid_token"'
    end

    it "asks for a token" do
      rpc(nil, "tools/list")

      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to eq(expected_header)
    end

    it "refuses an expired access token with 401 so the client refreshes" do
      a = connect("parent-a", "zsdemo")
      later = now + 3601
      allow(clock).to receive(:call).and_return(later)

      rpc(a.access_token, "tools/list")
      expect(last_response.status).to eq(401)
      expect(last_response.headers["WWW-Authenticate"]).to eq(expected_header)
    end

    it "ignores a token in the query string" do
      a = connect("parent-a", "zsdemo")
      post "/mcp?access_token=#{a.access_token}", JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")

      expect(last_response.status).to eq(401)
    end
  end

  context "with the stored sessions (also after a restart)" do
    let(:runtimes) { public_ns::Runtimes.new(data_dir: Edupage::Config.cache_dir) }

    it "answers a reconnect tool error once Edupage ends the session, without logging in again" do
      expect(Edupage::Client).not_to receive(:mauth)
      stub_request(:any, /zsother\.edupage\.org/)
        .to_return(status: 302, headers: { "Location" => "https://zsother.edupage.org/login/" })
      a = connect("parent-a", "zsother")

      response = call_tool(a.access_token, "edupage_students", "school" => "zsother")
      expect(last_response.status).to eq(200)
      expect(response.dig("result", "isError")).to be(true)
      expect(tool_text(response)).to eq("Prihlásenie do Edupage pre zsother vypršalo. Odpoj a znova pripoj " \
                                        "Edupage konektor.")
      expect(grants.find(a.grant_id)).not_to be_nil
    end
  end
end
