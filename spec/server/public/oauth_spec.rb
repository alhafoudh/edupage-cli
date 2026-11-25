require "rack/test"

RSpec.describe Edupage::Server::Public::App do
  include Rack::Test::Methods

  def app = described_class

  let(:public_ns) { Edupage::Server::Public }
  let(:settings) do
    public_ns::Settings.new(public_url: "https://mcp.example.com", secret_key: "k" * 32,
                            data_dir: Edupage::Config.cache_dir)
  end
  let(:store) { public_ns::Store.new(File.join(Edupage::Config.cache_dir, "o.sqlite3")) }
  let(:grants) { public_ns::Grants.new(store: store, pepper: settings.pepper) }
  let(:clients) { public_ns::Clients.new(store: store) }
  let(:pending) { public_ns::Pending.new }
  let(:runtimes) { double("Runtimes") }
  let(:web_login) { instance_double(Edupage::WebLogin) }
  let(:flow) do
    public_ns::LoginFlow.new(pending: pending, rate_limiter: public_ns::RateLimiter.new, grants: grants,
                             issuer: settings.issuer, web_login: ->(**_) { web_login })
  end
  let(:verifier) { "v" * 50 }
  let(:challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }
  let(:claude_cb) { "https://claude.ai/api/mcp/auth_callback" }
  let(:mauth_entries) do
    [{ origin: "zsdemo", session_id: "sid", userid: "Rodic-1", role: "Rodic", first_name: "A",
       last_name: "B", needs_2fa: false }]
  end

  before do
    described_class.configure_with(settings: settings, clients: clients, grants: grants, flow: flow,
                                   pending: pending, runtimes: runtimes)
    allow(Edupage::Client).to receive(:mauth) do |password:, **|
      raise Edupage::BadCredentialsError, "Incorrect password" unless password == "right"

      mauth_entries
    end
  end

  def json = JSON.parse(last_response.body)

  def register(redirect = claude_cb)
    post "/oauth/register", JSON.generate("redirect_uris" => [redirect], "client_name" => "Claude"),
         "CONTENT_TYPE" => "application/json"
    json["client_id"]
  end

  def authorize_params(client_id, redirect = claude_cb, **extra)
    { response_type: "code", client_id: client_id, redirect_uri: redirect, state: "st",
      code_challenge: challenge, code_challenge_method: "S256",
      resource: "https://mcp.example.com/mcp" }.merge(extra)
  end

  def form_values
    { pending_id: last_response.body[/name="pending_id" value="([^"]+)"/, 1],
      csrf: last_response.body[/name="csrf" value="([^"]+)"/, 1] }
  end

  def log_in(client_id, password: "right")
    get "/oauth/authorize", authorize_params(client_id)
    values = form_values
    post "/oauth/authorize", values.merge(school: "zsdemo", username: "parent@example.com", password: password)
    values
  end

  def code_from_redirect
    URI.decode_www_form(URI(last_response.location).query).to_h
  end

  describe "metadata" do
    it "describes the protected resource" do
      %w[/.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/mcp].each do |path|
        get path
        expect(json).to eq("resource" => "https://mcp.example.com/mcp",
                           "authorization_servers" => ["https://mcp.example.com"],
                           "bearer_methods_supported" => ["header"])
      end
    end

    it "describes the authorization server" do
      get "/.well-known/oauth-authorization-server"

      expect(json).to include(
        "issuer" => "https://mcp.example.com",
        "authorization_endpoint" => "https://mcp.example.com/oauth/authorize",
        "token_endpoint" => "https://mcp.example.com/oauth/token",
        "registration_endpoint" => "https://mcp.example.com/oauth/register",
        "revocation_endpoint" => "https://mcp.example.com/oauth/revoke",
        "response_types_supported" => ["code"],
        "grant_types_supported" => %w[authorization_code refresh_token],
        "code_challenge_methods_supported" => ["S256"],
        "token_endpoint_auth_methods_supported" => ["none"],
        "client_id_metadata_document_supported" => true
      )
    end
  end

  it "serves the bundled Edupage icon as its favicon" do
    get "/favicon.ico"

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to eq("image/x-icon")
    expect(last_response.body.b).to eq(File.binread(Edupage::Server::MCP::ICON_PATH))
  end

  describe "registration" do
    it "registers a client" do
      register
      expect(last_response.status).to eq(201)
      expect(json["client_id"]).to match(/\A\h{32}\z/)
    end

    it "rejects bad metadata" do
      post "/oauth/register", JSON.generate("redirect_uris" => ["http://evil.example/cb"]),
           "CONTENT_TYPE" => "application/json"

      expect(last_response.status).to eq(400)
      expect(json["error"]).to eq("invalid_client_metadata")
    end
  end

  describe "authorization" do
    it "runs the whole flow for Claude" do
      client_id = register
      get "/oauth/authorize", authorize_params(client_id)

      expect(last_response.status).to eq(200)
      body = last_response.body
      expect(body).to include("Pripojenie k Edupage")
      expect(body).to include("Tento server si tvoje heslo neukladá")
      expect(body).not_to include("uloží tvoje heslo")
      expect(body).to include("Prístup je iba na čítanie")
      expect(body).not_to include("Toto nie je Claude")
      expect(last_response.headers["X-Frame-Options"]).to eq("DENY")

      values = form_values
      post "/oauth/authorize", values.merge(school: "zsdemo", username: "parent@example.com", password: "right")
      expect(last_response.status).to eq(302)
      query = code_from_redirect
      expect(last_response.location).to start_with(claude_cb)
      expect(query).to include("state" => "st", "iss" => "https://mcp.example.com")

      post "/oauth/token", grant_type: "authorization_code", code: query["code"], redirect_uri: claude_cb,
                           client_id: client_id, code_verifier: verifier
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Cache-Control"]).to include("no-store")
      tokens = json
      expect(tokens).to include("token_type" => "Bearer", "expires_in" => 3600)

      post "/oauth/token", grant_type: "refresh_token", refresh_token: tokens["refresh_token"], client_id: client_id
      expect(last_response.status).to eq(200)
      refreshed = json

      post "/oauth/revoke", token: refreshed["access_token"]
      expect(last_response.status).to eq(200)

      post "/oauth/token", grant_type: "refresh_token", refresh_token: refreshed["refresh_token"], client_id: client_id
      expect(last_response.status).to eq(400)
      expect(json["error"]).to eq("invalid_grant")
    end

    it "warns when the client is not Claude" do
      client_id = register("https://evil.example/cb")
      get "/oauth/authorize", authorize_params(client_id, "https://evil.example/cb")

      expect(last_response.body).to include("Toto nie je Claude.")
      expect(last_response.body).to include("evil.example")
    end

    it "escapes the self-declared client name" do
      post "/oauth/register", JSON.generate("redirect_uris" => [claude_cb], "client_name" => "<script>x</script>"),
           "CONTENT_TYPE" => "application/json"
      get "/oauth/authorize", authorize_params(json["client_id"])

      expect(last_response.body).not_to include("<script>x</script>")
      expect(last_response.body).to include("&lt;script&gt;")
    end

    it "never redirects to an unregistered URI" do
      client_id = register
      get "/oauth/authorize", authorize_params(client_id, "https://evil.example/cb")

      expect(last_response.status).to eq(400)
      expect(last_response.location).to be_nil
    end

    it "refuses an unknown client without redirecting" do
      get "/oauth/authorize", authorize_params("nope")

      expect(last_response.status).to eq(400)
      expect(last_response.location).to be_nil
    end

    it "requires PKCE" do
      client_id = register
      get "/oauth/authorize", authorize_params(client_id).except(:code_challenge)

      expect(last_response.status).to eq(302)
      expect(code_from_redirect).to include("error" => "invalid_request", "state" => "st")
    end

    it "refuses another resource" do
      client_id = register
      get "/oauth/authorize", authorize_params(client_id, resource: "https://other.example/mcp")

      expect(code_from_redirect).to include("error" => "invalid_target")
    end

    it "refuses a forged form" do
      client_id = register
      get "/oauth/authorize", authorize_params(client_id)
      post "/oauth/authorize", form_values.merge(csrf: "forged", school: "zsdemo", username: "u", password: "right")

      expect(last_response.status).to eq(403)
    end

    it "shows the error on a wrong password" do
      client_id = register
      log_in(client_id, password: "wrong")

      expect(last_response.status).to eq(401)
      expect(last_response.body).to include("Nesprávne meno alebo heslo.")
    end

    it "refuses a school that is not a subdomain without contacting anyone" do
      client_id = register
      get "/oauth/authorize", authorize_params(client_id)
      post "/oauth/authorize", form_values.merge(school: "10.0.0.5:8443/x#", username: "u", password: "right")

      expect(last_response.status).to eq(400)
      expect(last_response.body).to include("Neplatná škola.")
      expect(Edupage::Client).not_to have_received(:mauth)
    end

    it "says so when the school does not exist" do
      allow(Edupage::Client).to receive(:mauth).and_raise(Edupage::NotFoundError, "No school zsnope on Edupage")
      log_in(register)

      expect(last_response.status).to eq(400)
      expect(last_response.body).to include("Škola zsdemo na Edupage neexistuje.")
    end

    it "shows a retry message when Edupage is down" do
      allow(Edupage::Client).to receive(:mauth).and_raise(Edupage::RequestError, "timeout")
      log_in(register)

      expect(last_response.status).to eq(502)
      expect(last_response.body).to include("Edupage sa nepodarilo kontaktovať")
    end

    it "shows the finished notice when another request already finished the login" do
      client_id = register
      get "/oauth/authorize", authorize_params(client_id)
      allow(flow).to receive(:finish).and_raise(public_ns::LoginFlow::Finished)
      post "/oauth/authorize", form_values.merge(school: "zsdemo", username: "parent@example.com", password: "right")

      expect(last_response.status).to eq(400)
      expect(last_response.body).to include("Toto prihlásenie už skončilo alebo vypršalo.")
    end

    it "explains a repeated submit of a finished login instead of failing" do
      client_id = register
      values = log_in(client_id)
      expect(last_response.status).to eq(302)

      post "/oauth/authorize", values.merge(school: "zsdemo", username: "parent@example.com", password: "right")
      expect(last_response.status).to eq(400)
      expect(last_response.body).to include("Toto prihlásenie už skončilo alebo vypršalo.")
      expect(store.instance_variable_get(:@db).execute("SELECT COUNT(*) AS n FROM grants").first["n"]).to eq(1)
    end
  end

  describe "two-factor" do
    let(:mauth_entries) do
      [{ origin: "zsdemo", session_id: "sid", userid: "Rodic-1", role: "Rodic", first_name: "A",
         last_name: "B", needs_2fa: true }]
    end
    let(:ok) do
      Edupage::WebLogin::Result.new(status: :ok, session_id: "sid2", userid: "Rodic-1", role: "Rodic", name: "A B")
    end

    before do
      allow(web_login).to receive(:start).and_return(Edupage::WebLogin::Result.new(status: :two_factor))
    end

    it "waits for the push approval and then redirects" do
      allow(web_login).to receive(:two_factor_info)
        .and_return(Edupage::WebLogin::TwoFactorInfo.new(device_names: ["iPhone"], email: "p***", channel: :push))
      allow(web_login).to receive(:poll).and_return(:waiting, "secret")
      allow(web_login).to receive(:complete).and_return(ok)

      values = log_in(register)
      expect(last_response.location).to include("/oauth/authorize/two-factor")

      get last_response.location
      expect(last_response.body).to include("Škola 1 z 1: <strong>zsdemo.edupage.org</strong>")
      expect(last_response.body).to include("Zadaj kód z aplikácie Edupage (iPhone)")
      expect(last_response.body).to include('name="code"')
      expect(last_response.body).not_to include("two-factor/email")

      post "/oauth/authorize/two-factor/poll", values
      expect(json).to eq("state" => "waiting")
      post "/oauth/authorize/two-factor/poll", values
      expect(json["state"]).to eq("done")
      expect(json["redirect"]).to start_with(claude_cb)
    end

    it "accepts the code shown in the app" do
      allow(web_login).to receive(:two_factor_info)
        .and_return(Edupage::WebLogin::TwoFactorInfo.new(device_names: ["iPhone"], email: "p***", channel: :push))
      allow(web_login).to receive(:complete).with("317951").and_return(ok)

      values = log_in(register)
      post "/oauth/authorize/two-factor/code", values.merge(code: "317951")

      expect(last_response.status).to eq(302)
      expect(last_response.location).to start_with(claude_cb)
    end

    it "shows a page, not a crash, when Edupage fails to start the two-factor step" do
      allow(web_login).to receive(:start).and_raise(Edupage::LoginError, "HTTP 502")
      log_in(register)
      get last_response.location

      expect(last_response.status).to eq(502)
      expect(last_response.content_type).to include("text/html")
      expect(last_response.body).to include("Edupage sa nepodarilo kontaktovať")
    end

    it "keeps polling through an Edupage hiccup" do
      allow(web_login).to receive(:two_factor_info)
        .and_return(Edupage::WebLogin::TwoFactorInfo.new(device_names: ["iPhone"], email: "p***", channel: :push))
      allow(web_login).to receive(:poll).and_raise(Edupage::LoginError, "timeout")
      values = log_in(register)
      get last_response.location

      post "/oauth/authorize/two-factor/poll", values
      expect(last_response.status).to eq(200)
      expect(json).to eq("state" => "waiting")
    end

    it "does not crash when re-sending fails" do
      allow(web_login).to receive(:two_factor_info)
        .and_return(Edupage::WebLogin::TwoFactorInfo.new(device_names: [], email: "p***", channel: :email))
      allow(web_login).to receive(:send_email).and_return(:sent)
      values = log_in(register)
      get last_response.location
      allow(web_login).to receive(:send_email).and_raise(Edupage::LoginError, "refused")

      post "/oauth/authorize/two-factor/email", values
      expect(last_response.status).to be < 500
    end

    it "asks for the e-mailed code when there is no device" do
      allow(web_login).to receive(:two_factor_info)
        .and_return(Edupage::WebLogin::TwoFactorInfo.new(device_names: [], email: "p***@example.com", channel: :email))
      allow(web_login).to receive(:send_email).and_return(:sent)
      allow(web_login).to receive(:complete).with("123456").and_return(ok)

      values = log_in(register)
      get last_response.location
      expect(last_response.body).to include("Kód sme poslali na p***@example.com")
      expect(last_response.body).to include('name="code"')

      post "/oauth/authorize/two-factor/code", values.merge(code: "123456")
      expect(last_response.status).to eq(302)
      expect(last_response.location).to start_with(claude_cb)
    end
  end
end
