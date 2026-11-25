RSpec.describe Edupage::Server::Public::Clients do
  subject(:clients) { described_class.new(store: store, fetcher: fetcher) }

  let(:store) { Edupage::Server::Public::Store.new(File.join(Edupage::Config.cache_dir, "c.sqlite3")) }
  let(:fetcher) { described_class::MetadataFetcher.new(resolver: ->(_host) { ["93.184.216.34"] }) }

  describe "#register" do
    it "registers a public client" do
      response = clients.register("redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
                                  "client_name" => "Claude", "token_endpoint_auth_method" => "none")

      expect(response).to include("client_id" => a_string_matching(/\A\h{32}\z/),
                                  "token_endpoint_auth_method" => "none",
                                  "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
                                  "grant_types" => %w[authorization_code refresh_token],
                                  "response_types" => ["code"])
      expect(clients.find(response["client_id"]).name).to eq("Claude")
    end

    it "accepts loopback redirects" do
      expect { clients.register("redirect_uris" => ["http://127.0.0.1:33418/callback"]) }.not_to raise_error
    end

    it "refuses missing redirect URIs" do
      expect { clients.register("client_name" => "x") }.to raise_error(described_class::InvalidMetadata)
    end

    it "refuses plain http on a public host" do
      expect { clients.register("redirect_uris" => ["http://evil.example/cb"]) }
        .to raise_error(described_class::InvalidMetadata)
    end

    it "refuses URIs with a fragment" do
      expect { clients.register("redirect_uris" => ["https://x.example/cb#frag"]) }
        .to raise_error(described_class::InvalidMetadata)
    end

    it "refuses confidential clients" do
      expect do
        clients.register("redirect_uris" => ["https://x.example/cb"], "token_endpoint_auth_method" => "client_secret_basic")
      end.to raise_error(described_class::InvalidMetadata)
    end
  end

  describe "client ID metadata documents" do
    let(:url) { "https://client.example/oauth/metadata.json" }

    def document(overrides = {})
      { "client_id" => url, "client_name" => "Example", "redirect_uris" => ["https://client.example/cb"] }
        .merge(overrides)
    end

    it "fetches the client from its URL" do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(document),
                                        headers: { "Content-Type" => "application/json" })

      client = clients.find(url)
      expect(client.redirect_uris).to eq(["https://client.example/cb"])
      expect(client.metadata_document?).to be(true)
    end

    it "refuses a document naming another client_id" do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(document("client_id" => "https://other.example/x")))

      expect(clients.find(url)).to be_nil
    end

    it "does not follow redirects" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://elsewhere.example/m.json" })

      expect(clients.find(url)).to be_nil
    end

    it "refuses oversized documents" do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(document("pad" => "x" * 20_000)))

      expect(clients.find(url)).to be_nil
    end

    it "refuses hosts that resolve to private or reserved addresses" do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(document))

      %w[10.0.0.1 100.100.1.1 0.1.2.3 198.18.0.1 224.0.0.1 169.254.169.254 fd00::1 64:ff9b::a00:1 ::ffff:10.0.0.1].each do |ip|
        private_fetcher = described_class::MetadataFetcher.new(resolver: ->(_host) { [ip] })
        expect(described_class.new(store: store, fetcher: private_fetcher).find(url)).to be_nil, ip
      end
    end

    it "treats a dropped connection as no document" do
      stub_request(:get, url).to_raise(EOFError)

      expect(clients.find(url)).to be_nil
    end
  end

  describe "redirect rules" do
    let(:client) { described_class::Client.new(id: "c", name: "n", redirect_uris: uris, metadata_document: false) }
    let(:uris) { ["https://claude.ai/api/mcp/auth_callback", "http://127.0.0.1:1234/cb"] }

    it "matches exactly" do
      expect(clients.redirect_matches?(client, "https://claude.ai/api/mcp/auth_callback")).to be(true)
      expect(clients.redirect_matches?(client, "https://claude.ai/api/mcp/auth_callback/")).to be(false)
    end

    it "ignores the port of loopback redirects" do
      expect(clients.redirect_matches?(client, "http://127.0.0.1:5555/cb")).to be(true)
      expect(clients.redirect_matches?(client, "http://127.0.0.1:5555/other")).to be(false)
    end

    it "recognises Claude" do
      expect(clients.claude?("https://claude.ai/api/mcp/auth_callback")).to be(true)
      expect(clients.claude?("https://claude.com/api/mcp/auth_callback")).to be(true)
      expect(clients.claude?("https://claude.ai.evil.example/cb")).to be(false)
    end
  end
end
