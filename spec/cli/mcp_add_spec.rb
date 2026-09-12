require "edupage/cli"

RSpec.describe "edupage mcp-add" do
  def run(*args)
    capture(*args).first
  end

  # Thor turns a Thor::Error into an exit(1) after printing to stderr, so failures are
  # asserted through the message rather than the exception class.
  def capture(*args)
    out = StringIO.new
    err = StringIO.new
    original = [$stdout, $stderr]
    $stdout, $stderr = out, err
    begin
      Edupage::CLI.start(["mcp-add", *args])
      [out.string, err.string, 0]
    rescue SystemExit => e
      [out.string, err.string, e.status]
    end
  ensure
    $stdout, $stderr = original
  end

  def failure_message(*args)
    _out, err, status = capture(*args)
    expect(status).not_to eq(0), "expected `mcp-add #{args.join(" ")}` to fail"
    err
  end

  it "rejects a missing or unknown target" do
    expect(failure_message).to match(/TARGET/)
    expect(failure_message("nonsense")).to match(/claude-code, claude-desktop, all/)
  end

  describe "--dry-run" do
    # The point of the flag: see exactly what would happen without touching anyone's
    # config. Nothing below may write a file or shell out.
    before do
      allow_any_instance_of(Edupage::CLI).to receive(:system) { raise "must not run anything" }
      allow(File).to receive(:rename) { raise "must not write anything" }
    end

    it "shows the claude mcp add line for Claude Code" do
      output = run("claude-code", "--dry-run")

      expect(output).to include("would run")
      expect(output).to match(/claude mcp add .*edupage/)
      expect(output).to include(" -- ")
    end

    it "shows the file and the entry for Claude Desktop" do
      output = run("claude-desktop", "--dry-run")

      expect(output).to include("claude_desktop_config.json")
      expect(output).to match(/would (add|replace) "edupage"/)
      expect(output).to include("BUNDLE_GEMFILE")
    end

    it "covers both targets with all" do
      output = run("all", "--dry-run")

      expect(output).to include("claude-code")
      expect(output).to include("claude-desktop")
    end

    it "shows the HTTP entry with its token when asked" do
      output = run("claude-desktop", "--http", "--dry-run")

      expect(output).to include("Bearer #{Edupage.config.server_token}")
      expect(output).to include("/mcp")
    end

    it "includes the scope in the generated Claude Code line" do
      expect(run("claude-code", "--dry-run", "--scope", "user")).to include("-s user")
    end

    it "names the entry" do
      expect(run("claude-desktop", "--dry-run", "--name", "skola")).to include('"skola"')
    end
  end

  describe "writing the Claude Desktop config" do
    let(:path) { File.join(Edupage::Config.cache_dir, "claude_desktop_config.json") }

    before do
      stub_const("Edupage::CLI::CLAUDE_DESKTOP_CONFIG", path)
      FileUtils.mkdir_p(File.dirname(path))
    end

    def config = JSON.parse(File.read(path))

    it "creates the file when there is none" do
      run("claude-desktop")

      expect(config.dig("mcpServers", "edupage", "args")).to include("mcp")
    end

    it "keeps other servers and unrelated top-level keys" do
      # Claude Desktop stores preferences in the same file; clobbering them would be a
      # nasty surprise.
      File.write(path, JSON.generate(
                         "mcpServers" => { "keyboard-maestro" => { "command" => "km" } },
                         "preferences" => { "theme" => "dark" }
                       ))

      run("claude-desktop")

      expect(config["mcpServers"].keys).to contain_exactly("keyboard-maestro", "edupage")
      expect(config["preferences"]).to eq("theme" => "dark")
    end

    it "is idempotent: running it twice changes nothing the second time" do
      run("claude-desktop")
      first = File.read(path)

      output = run("claude-desktop")

      expect(output).to match(/already up to date/)
      expect(File.read(path)).to eq(first)
    end

    it "brings a differing entry into line without being asked twice" do
      run("claude-desktop")
      output = run("claude-desktop", "--http")

      expect(output).to match(/updated/)
      expect(config.dig("mcpServers", "edupage", "type")).to eq("http")
      expect(File.exist?("#{path}.bak")).to be(true)
    end

    it "writes a file only the owner can read, since it carries the token" do
      run("claude-desktop", "--http")

      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "refuses to touch a file that is not valid JSON" do
      # Better to stop than to replace a config we cannot read with a fresh one.
      File.write(path, "{ broken")

      expect(failure_message("claude-desktop")).to match(/not valid JSON/)
      expect(File.read(path)).to eq("{ broken")
    end
  end
end
