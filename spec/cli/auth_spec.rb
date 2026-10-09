require "edupage/cli"
require "tty-screen"

RSpec.describe "edupage auth" do
  def run(*args)
    out = StringIO.new
    original = $stdout
    $stdout = out
    Edupage::CLI.start(["auth", *args])
    out.string
  ensure
    $stdout = original
  end

  before { allow(TTY::Screen).to receive(:width).and_return(120) }

  it "leaves the system store alone when EDUPAGE_PASSWORD is set" do
    ENV["EDUPAGE_USERNAME"] = "u"
    ENV["EDUPAGE_PASSWORD"] = "from-env"
    Edupage::Credentials::SYSTEM_ADAPTERS.each do |adapter|
      allow(adapter).to receive(:new).and_raise("#{adapter} must not be built")
    end

    expect(run).to include("ENV: EDUPAGE_PASSWORD").and include("not consulted (EDUPAGE_PASSWORD set)")
  end

  it "reports a password found in the system store" do
    ENV["EDUPAGE_USERNAME"] = "u"
    store = instance_double(Edupage::Credentials::Adapters::MacosKeychain,
                            password: "stored", source_for: "keychain", display_name: "macOS keychain")
    allow(Edupage::Credentials).to receive(:system_adapter).and_return(store)

    expect(run).to include("[keychain]").and include("macOS keychain, stored for u")
  end

  it "says when there is no store on this platform" do
    ENV["EDUPAGE_USERNAME"] = "u"
    allow(Edupage::Credentials).to receive(:system_adapter).and_return(nil)

    expect(run).to include("unavailable on #{RUBY_PLATFORM}")
  end
end
