require "edupage/cli"

RSpec.describe "edupage mcp-config" do
  def run(*args)
    out = StringIO.new
    err = StringIO.new
    original = [$stdout, $stderr]
    $stdout, $stderr = out, err
    Edupage::CLI.start(["mcp-config", *args])
    [out.string, err.string]
  ensure
    $stdout, $stderr = original
  end

  def entry(*args, name: "edupage")
    stdout, = run(*args)
    JSON.parse(stdout).dig("mcpServers", name)
  end

  it "prints the JSON and nothing else" do
    # `edupage mcp-config > entry.json` has to produce a usable file, so not a single
    # byte of commentary may escape onto either stream.
    stdout, stderr = run

    expect { JSON.parse(stdout) }.not_to raise_error
    expect(stderr).to be_empty
  end

  describe "stdio (the default)" do
    it "runs the mcp command" do
      expect(entry["args"]).to include("mcp")
    end

    it "uses absolute paths and pins BUNDLE_GEMFILE" do
      # MCP clients start servers with a working directory of their own, so a relative
      # path or an inherited Gemfile would not survive.
      result = entry

      expect(result["command"]).to start_with("/")
      expect(result["args"].first(2)).to eq(["exec", File.expand_path($PROGRAM_NAME)])
      expect(result["env"]["BUNDLE_GEMFILE"]).to start_with("/")
    end

    it "carries no token, because stdio has nothing to authenticate" do
      expect(entry.to_s).not_to include("Bearer")
      expect(entry).not_to have_key("headers")
    end

    it "does not pin a school or student" do
      # Those are levels of the chain; the model has to choose them per call.
      expect(entry["args"]).not_to include("--school", "--student")
    end
  end

  describe "--http" do
    it "points at the streamable HTTP endpoint with a bearer token" do
      result = entry("--http")

      expect(result["type"]).to eq("http")
      expect(result["url"]).to end_with("/mcp")
      expect(result["headers"]["Authorization"]).to eq("Bearer #{Edupage.config.server_token}")
    end

    it "honours an explicit host and port" do
      result = entry("--http", "--host", "0.0.0.0", "--port", "9999")

      expect(result["url"]).to eq("http://0.0.0.0:9999/mcp")
    end

    it "reuses the token already in the config rather than minting a new one" do
      token = Edupage.config.server_token

      expect(entry("--http")["headers"]["Authorization"]).to eq("Bearer #{token}")
      expect(entry("--http")["headers"]["Authorization"]).to eq("Bearer #{token}")
    end
  end

  it "names the entry" do
    expect(entry("--name", "skola", name: "skola")).not_to be_nil
  end
end
