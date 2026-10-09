RSpec.describe Edupage::Credentials::SystemAdapter do
  # An in-memory store, so the shared contract and the guards in the base class run on
  # every platform, not only where a real store exists.
  let(:memory_store) do
    Class.new(described_class) do
      def self.available? = true
      def self.display_name = "memory store"

      def initialize(**)
        super
        @entries = {}
      end

      def source_for(_field) = "memory"

      private

      def read(username) = @entries[username]
      def write(username, secret) = (@entries[username] = secret)
      def remove(username) = !@entries.delete(username).nil?
    end
  end

  it_behaves_like "a system credential adapter" do
    let(:adapter) { memory_store.new(service: service) }
  end

  it "raises when a write does not read back" do
    lossy = Class.new(memory_store) do
      private

      def write(username, secret) = super(username, secret.chop)
    end

    expect { lossy.new.store(username: "u", password: "hunter2") }
      .to raise_error(Edupage::Error, /memory store reported success but stored a different password/)
  end

  context "when the store is not available" do
    let(:absent) do
      Class.new(memory_store) do
        def self.available? = false

        private

        def read(_username) = raise("must not be called")
      end
    end

    it "returns no password without calling the store" do
      expect(absent.new.password(username: "u")).to be_nil
    end

    it "refuses to store or delete" do
      expect { absent.new.store(username: "u", password: "x") }
        .to raise_error(Edupage::UnsupportedPlatformError, /memory store is not available/)
      expect { absent.new.delete(username: "u") }.to raise_error(Edupage::UnsupportedPlatformError)
    end
  end

  it "uses the edupage-cli service by default" do
    expect(memory_store.new.service).to eq("edupage-cli")
  end
end

RSpec.describe Edupage::Credentials::Adapter do
  it "leaves the platform-specific parts abstract" do
    expect { described_class.available? }.to raise_error(NotImplementedError)
    expect { described_class.display_name }.to raise_error(NotImplementedError)
    expect { described_class.new.source_for(:password) }.to raise_error(NotImplementedError)
  end

  it "supplies nothing and is read-only by default" do
    adapter = described_class.new

    expect([adapter.username, adapter.school, adapter.password]).to all(be_nil)
    expect(adapter).not_to be_writable
  end
end
