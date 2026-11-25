RSpec.describe Edupage::Server::Public::Settings do
  let(:key) { Base64.strict_encode64("k" * 32) }
  let(:env) do
    { "EDUPAGE_PUBLIC_URL" => "https://mcp.example.com/", "EDUPAGE_SECRET_KEY" => key,
      "EDUPAGE_DATA_DIR" => "/tmp/edupage-data" }
  end

  it "derives the OAuth identifiers from the public URL" do
    settings = described_class.from_env(env)

    expect(settings.public_url).to eq("https://mcp.example.com")
    expect(settings.issuer).to eq("https://mcp.example.com")
    expect(settings.resource).to eq("https://mcp.example.com/mcp")
    expect(settings.host).to eq("mcp.example.com")
    expect(settings.pepper).to eq("k" * 32)
    expect(settings.data_dir).to eq("/tmp/edupage-data")
    expect(settings.trust_proxy?).to be(false)
  end

  it "lets the option override the env URL" do
    expect(described_class.from_env(env, public_url: "https://other.example").resource)
      .to eq("https://other.example/mcp")
  end

  it "accepts a hex key" do
    expect(described_class.from_env(env.merge("EDUPAGE_SECRET_KEY" => "ab" * 32)).pepper.bytesize).to eq(32)
  end

  it "reads the proxy switch" do
    expect(described_class.from_env(env.merge("EDUPAGE_TRUST_PROXY" => "1")).trust_proxy?).to be(true)
  end

  it "allows plain http on localhost only" do
    expect(described_class.from_env(env.merge("EDUPAGE_PUBLIC_URL" => "http://localhost:4567")).host)
      .to eq("localhost")
    expect { described_class.from_env(env.merge("EDUPAGE_PUBLIC_URL" => "http://mcp.example.com")) }
      .to raise_error(Edupage::Error, /EDUPAGE_PUBLIC_URL/)
  end

  it "requires the public URL" do
    expect { described_class.from_env(env.except("EDUPAGE_PUBLIC_URL")) }
      .to raise_error(Edupage::Error, /EDUPAGE_PUBLIC_URL/)
  end

  it "requires a long enough secret key" do
    expect { described_class.from_env(env.except("EDUPAGE_SECRET_KEY")) }
      .to raise_error(Edupage::Error, /EDUPAGE_SECRET_KEY/)
    expect { described_class.from_env(env.merge("EDUPAGE_SECRET_KEY" => "short")) }
      .to raise_error(Edupage::Error, /EDUPAGE_SECRET_KEY/)
  end

  it "keeps the pepper out of inspect" do
    expect(described_class.from_env(env).inspect).not_to include("k" * 32)
  end
end
