RSpec.describe Edupage::Credentials::Adapters::MacosKeychain do
  it_behaves_like "a system credential adapter"

  describe "talking to security" do
    let(:adapter) { described_class.new(service: "edupage-cli-spec-#{Process.pid}") }
    let(:username) { "spec-user" }

    after { adapter.delete(username: username) }

    it "never passes the password in argv" do
      # `security` exits 0 even when its two stdin reads disagree, so the password must
      # arrive on stdin (twice, for the retype prompt) and never via -w <value>, where
      # `ps` would expose it.
      captured = nil
      allow(Open3).to receive(:capture3).and_wrap_original do |original, *args, **kwargs|
        captured = [args, kwargs] if args.include?("add-generic-password")
        original.call(*args, **kwargs)
      end

      adapter.store(username: username, password: "hunter2")

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

      expect { adapter.store(username: username, password: "hunter2") }
        .to raise_error(Edupage::Error, /stored a different password/)
    end
  end
end
