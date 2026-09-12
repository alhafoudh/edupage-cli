RSpec.describe Edupage::Credentials::Keychain, :keychain do
  # A dedicated service name so a failing run can never touch a real entry.
  let(:service) { "edupage-cli-spec-#{Process.pid}" }
  let(:keychain) { described_class.new(service: service) }
  let(:username) { "spec-user" }

  after { keychain.delete(username: username) }

  describe "round-tripping passwords" do
    # `security -w` hex-encodes non-ASCII passwords, which is ambiguous against an
    # ASCII password that already looks like hex. These cases pin that behaviour down.
    {
      "plain ascii" => "plain-ascii",
      "hex-looking ascii" => "deadbeef",
      "accented utf-8" => "s3cr3t-áčž",
      "quotes and backslashes" => 'pa"ss\\word',
      "spaces and punctuation" => "with spaces and #hash",
      "emoji" => "p❤️ss"
    }.each do |label, secret|
      it "survives #{label}" do
        keychain.store(username: username, password: secret)

        expect(keychain.password(username: username)).to eq(secret)
      end
    end
  end

  it "reports nothing for an unknown account" do
    expect(keychain.password(username: "no-such-account")).to be_nil
    expect(keychain.stored?(username: "no-such-account")).to be(false)
  end

  it "overwrites an existing entry" do
    keychain.store(username: username, password: "first")
    keychain.store(username: username, password: "second")

    expect(keychain.password(username: username)).to eq("second")
  end

  it "deletes an entry" do
    keychain.store(username: username, password: "x")

    expect(keychain.delete(username: username)).to be(true)
    expect(keychain.stored?(username: username)).to be(false)
  end

  it "refuses an empty password" do
    expect { keychain.store(username: username, password: "") }.to raise_error(ArgumentError)
  end

  it "never passes the password in argv" do
    # `security` exits 0 even when its two stdin reads disagree, so the password must
    # arrive on stdin (twice, for the retype prompt) and never via -w <value>, where
    # `ps` would expose it.
    captured = nil
    allow(Open3).to receive(:capture3).and_wrap_original do |original, *args, **kwargs|
      captured = [args, kwargs] if args.include?("add-generic-password")
      original.call(*args, **kwargs)
    end

    keychain.store(username: username, password: "hunter2")

    args, kwargs = captured
    expect(args).not_to include("hunter2")
    expect(kwargs[:stdin_data]).to eq("hunter2\nhunter2\n")
  end

  it "raises rather than silently storing a mismatched password" do
    # The failure mode this guards: security exits 0 but persists an empty password.
    allow(Open3).to receive(:capture3).and_wrap_original do |original, *args, **kwargs|
      next ["", "", instance_double(Process::Status, success?: true)] if args.include?("add-generic-password")

      original.call(*args, **kwargs)
    end

    expect { keychain.store(username: username, password: "hunter2") }
      .to raise_error(Edupage::Error, /stored a different password/)
  end

  it "only supplies a password, never a username or school" do
    expect(keychain.username).to be_nil
    expect(keychain.school).to be_nil
  end
end
