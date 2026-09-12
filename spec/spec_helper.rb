require "tmpdir"

require "edupage"
# Loaded eagerly so the safety stub below can reach the constant in every spec, not
# only the ones that require the CLI themselves.
require "edupage/cli"
require_relative "support/vcr"
require_relative "support/payloads"
require_relative "support/fake_session"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |c| c.verify_partial_doubles = true }

  config.disable_monkey_patching!
  config.filter_run_when_matching :focus
  config.order = :random
  Kernel.srand config.seed

  # Every example gets its own config/cache root so nothing touches the real
  # ~/.config/edupage-cli or ~/.cache/edupage-cli.
  config.around do |example|
    Dir.mktmpdir("edupage-spec") do |dir|
      ENV["EDUPAGE_CONFIG"] = File.join(dir, "config.yml")
      ENV["EDUPAGE_CACHE_DIR"] = File.join(dir, "cache")
      Edupage.config = Edupage::Config.load
      Edupage.reset!
      example.run
    ensure
      ENV.delete("EDUPAGE_CONFIG")
      ENV.delete("EDUPAGE_CACHE_DIR")
      Edupage.config = nil
      Edupage.reset!
    end
  end

  # Guards against a spec accidentally reading the developer's own credentials.
  config.before do
    %w[EDUPAGE_USERNAME EDUPAGE_PASSWORD EDUPAGE_SCHOOL].each { |k| ENV.delete(k) }
  end

  # mcp-add writes real config files. Point that path at the per-example temp directory
  # for every spec, so no test can reach the developer's actual Claude Desktop config
  # even if it forgets to stub it itself.
  config.before do
    stub_const(
      "Edupage::CLI::CLAUDE_DESKTOP_CONFIG",
      File.join(Edupage::Config.cache_dir, "claude_desktop_config.json")
    )
  end

  config.define_derived_metadata(file_path: %r{/keychain}) do |meta|
    meta[:keychain] = true
  end

  config.filter_run_excluding(keychain: true) unless Edupage::Credentials::Keychain.available?
end

def fixture(name)
  File.read(File.join(__dir__, "fixtures", name))
end

def fixture_path(name)
  File.join(__dir__, "fixtures", name)
end
