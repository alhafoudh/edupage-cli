require "open3"

RSpec.describe Edupage::Credentials::Adapters::WindowsCredentialManager do
  it_behaves_like "a system credential adapter"

  describe "entries" do
    let(:adapter) { described_class.new(service: "edupage-cli-spec-#{Process.pid}") }
    let(:username) { "spec-user" }

    after { adapter.delete(username: username) }

    it "names the target after service and username" do
      expect(adapter.target_name(username)).to eq("edupage-cli-spec-#{Process.pid}:spec-user")
    end

    it "is visible to cmdkey under that target" do
      adapter.store(username: username, password: "hunter2")

      out, _status = Open3.capture2("cmdkey", "/list:#{adapter.target_name(username)}")
      expect(out).to include(adapter.target_name(username))
    end

    it "handles a non-ASCII username" do
      adapter.store(username: "žiak-ä", password: "hunter2")

      expect(adapter.password(username: "žiak-ä")).to eq("hunter2")
    ensure
      adapter.delete(username: "žiak-ä")
    end
  end
end
