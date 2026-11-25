require "rack/test"

RSpec.describe Edupage::Server::Public do
  include Rack::Test::Methods

  let(:settings) do
    described_class::Settings.new(public_url: "https://mcp.example.com", secret_key: "k" * 32,
                                  data_dir: File.join(Edupage::Config.cache_dir, "data"))
  end
  let(:components) { described_class.components(settings) }
  let(:app) { described_class.build_app(settings, components) }

  it "serves the health check and not the REST API" do
    get "/healthz"
    expect(last_response.status).to eq(200)

    get "/api/v1/schools"
    expect(last_response.status).to eq(404)
  end

  it "keeps the database in the data directory" do
    components
    expect(File.exist?(File.join(settings.data_dir, "edupage.sqlite3"))).to be(true)
  end

  it "cleans up stale grants together with their runtimes" do
    allow(components.grants).to receive(:cleanup!).and_return(["a" * 32])
    allow(components.runtimes).to receive(:forget)
    allow(components.runtimes).to receive(:evict_idle!)

    described_class.cleanup!(components)

    expect(components.runtimes).to have_received(:forget).with("a" * 32)
    expect(components.runtimes).to have_received(:evict_idle!)
  end

  it "drops the runtime and cached data of every deleted grant" do
    grants = components.grants
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest("v" * 50), padding: false)
    grant_id, code = grants.issue_code(client_id: "c", credentials: { username: "u" }, redirect_uri: "https://x/cb",
                                       code_challenge: challenge, resource: "r")
    tokens = grants.exchange_code(code, client_id: "c", redirect_uri: "https://x/cb", code_verifier: "v" * 50)
    FileUtils.mkdir_p(components.runtimes.cache_root(grant_id))

    grants.revoke(tokens.access_token)

    expect(Dir.exist?(components.runtimes.cache_root(grant_id))).to be(false)
  end

  it "sweeps cache directories that no grant owns" do
    orphan = components.runtimes.cache_root("f" * 32)
    FileUtils.mkdir_p(orphan)

    described_class.cleanup!(components)

    expect(Dir.exist?(orphan)).to be(false)
  end

  describe ".start" do
    around do |example|
      saved = ENV.to_h.slice("EDUPAGE_PUBLIC_URL", "EDUPAGE_SECRET_KEY", "EDUPAGE_DATA_DIR")
      example.run
    ensure
      %w[EDUPAGE_PUBLIC_URL EDUPAGE_SECRET_KEY EDUPAGE_DATA_DIR].each { |k| ENV.delete(k) }
      ENV.update(saved)
    end

    it "fails before binding when the secret key is missing" do
      ENV["EDUPAGE_PUBLIC_URL"] = "https://mcp.example.com"
      ENV.delete("EDUPAGE_SECRET_KEY")
      expect(Edupage::Server).not_to receive(:run)

      expect { described_class.start(host: "127.0.0.1", port: 0) }.to raise_error(Edupage::Error, /EDUPAGE_SECRET_KEY/)
    end

    it "starts without touching the bearer token of the local server" do
      ENV["EDUPAGE_PUBLIC_URL"] = "https://mcp.example.com"
      ENV["EDUPAGE_SECRET_KEY"] = "k" * 32
      ENV["EDUPAGE_DATA_DIR"] = File.join(Edupage::Config.cache_dir, "data")
      allow(Edupage::Server).to receive(:run)
      allow(Thread).to receive(:new)
      expect(Edupage::Server::Auth).not_to receive(:token)

      expect { described_class.start(host: "127.0.0.1", port: 4567) }.to output(/mcp\.example\.com\/mcp/).to_stderr
      expect(Edupage::Server).to have_received(:run)
    end
  end

  it "is reached through `edupage server --public`" do
    expect(Edupage::Server).to receive(:start).with(hash_including(public: true, public_url: "https://x.example"))

    Edupage::CLI.start(%w[server --public --public-url https://x.example])
  end
end
