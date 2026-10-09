RSpec.describe Edupage::Credentials::Adapters::SecretService do
  it_behaves_like "a system credential adapter"

  describe "talking to secret-tool" do
    let(:adapter) { described_class.new(service: "edupage-cli-spec-#{Process.pid}") }
    let(:username) { "spec-user" }

    after { adapter.delete(username: username) }

    it "never passes the password in argv" do
      captured = nil
      allow(Open3).to receive(:capture3).and_wrap_original do |original, *args, **kwargs|
        captured = [args, kwargs] if args.include?("store")
        original.call(*args, **kwargs)
      end

      adapter.store(username: username, password: "hunter2")

      args, kwargs = captured
      expect(args).not_to include("hunter2")
      expect(kwargs[:stdin_data]).to eq("hunter2")
    end

    it "keys entries by service and account" do
      adapter.store(username: username, password: "hunter2")

      out, _err, status = Open3.capture3(
        described_class.executable, "lookup", "service", adapter.service, "account", username
      )
      expect(status).to be_success
      expect(out).to eq("hunter2")
    end
  end
end
