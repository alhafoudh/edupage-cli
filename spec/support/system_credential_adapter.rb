# Behaviour every OS credential store must share. Each adapter spec runs this against
# the real store, so it is only included where that store exists (see spec_helper).
RSpec.shared_examples "a system credential adapter" do
  # A dedicated service name so a failing run can never touch a real entry.
  let(:service) { "edupage-cli-spec-#{Process.pid}" }
  let(:adapter) { described_class.new(service: service) }
  let(:username) { "spec-user" }

  after { adapter.delete(username: username) }

  describe "round-tripping passwords" do
    # The macOS keychain hex-encodes non-ASCII passwords, which is ambiguous against an
    # ASCII password that already looks like hex; the others store raw bytes. These
    # cases pin the encoding down everywhere.
    {
      "plain ascii" => "plain-ascii",
      "hex-looking ascii" => "deadbeef",
      "accented utf-8" => "s3cr3t-áčž",
      "quotes and backslashes" => 'pa"ss\\word',
      "spaces and punctuation" => "with spaces and #hash",
      "emoji" => "p❤️ss"
    }.each do |label, secret|
      it "survives #{label}" do
        adapter.store(username: username, password: secret)

        expect(adapter.password(username: username)).to eq(secret)
      end
    end
  end

  it "reports nothing for an unknown account" do
    expect(adapter.password(username: "no-such-account")).to be_nil
    expect(adapter.stored?(username: "no-such-account")).to be(false)
  end

  it "overwrites an existing entry" do
    adapter.store(username: username, password: "first")
    adapter.store(username: username, password: "second")

    expect(adapter.password(username: username)).to eq("second")
  end

  it "deletes an entry" do
    adapter.store(username: username, password: "x")

    expect(adapter.delete(username: username)).to be(true)
    expect(adapter.stored?(username: username)).to be(false)
  end

  it "reports false when deleting an unknown account" do
    expect(adapter.delete(username: "no-such-account")).to be(false)
  end

  it "refuses an empty password" do
    expect { adapter.store(username: username, password: "") }.to raise_error(ArgumentError)
  end

  it "only supplies a password, never a username or school" do
    expect(adapter.username).to be_nil
    expect(adapter.school).to be_nil
  end

  it "is writable and names itself" do
    expect(adapter).to be_writable
    expect(adapter.display_name).to be_a(String)
    expect(adapter.source_for(:password)).to be_a(String)
  end
end
