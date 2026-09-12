require "edupage/cli"

RSpec.describe "edupage mcp-config" do
  # The JSON must go to stdout on its own so it can be piped straight into a config
  # file; the placement notes belong on stderr.
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

  it "emits valid JSON on stdout and nothing else" do
    stdout, stderr = run

    expect { JSON.parse(stdout) }.not_to raise_error
    expect(stderr).to include("Claude Code", "Claude Desktop")
    expect(stdout).not_to include("Claude Desktop")
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

    it "says the server has to be running" do
      _, stderr = run("--http")

      expect(stderr).to match(/edupage server/)
    end
  end

  it "names the entry" do
    expect(entry("--name", "skola", name: "skola")).not_to be_nil
  end

  describe "--command" do
    def command(*args) = run("--command", *args).first.strip

    it "emits a stdio `claude mcp add` line with env before the -- separator" do
      line = command

      expect(line).to start_with("claude mcp add ")
      expect(line).to match(/-e BUNDLE_GEMFILE=\S+/)
      expect(line).to include(" -- ")
      expect(line.split(" -- ").last).to include("mcp")
    end

    it "emits an http `claude mcp add` line with the token as a header" do
      line = command("--http")

      expect(line).to include("--transport http")
      expect(line).to include("/mcp")
      expect(line).to include("--header 'Authorization: Bearer #{Edupage.config.server_token}'")
    end

    it "quotes only what needs it, and survives a round trip through the shell" do
      # Readability matters here - the line is meant to be pasted - but it still has to
      # parse back to the same arguments.
      argv = Shellwords.split(command("--http"))

      expect(argv.first(3)).to eq(%w[claude mcp add])
      expect(argv.last).to eq("Authorization: Bearer #{Edupage.config.server_token}")
      expect(command).not_to include("\\=")
    end

    it "prints nothing but the command" do
      stdout, stderr = run("--command")

      expect(stdout.lines.size).to eq(1)
      expect(stderr).to be_empty
      expect { JSON.parse(stdout) }.to raise_error(JSON::ParserError)
    end
  end

  it "suggests the claude command alongside the JSON" do
    _, stderr = run

    expect(stderr).to include("claude mcp add")
  end
end
