RSpec.describe Edupage::SessionStore do
  subject(:store) { described_class.new(path: path) }

  let(:path) { File.join(Edupage::Config.cache_dir, "sessions.json") }

  it "round-trips a session" do
    store.store("u@example.com", "zsdemo", session_id: "abc", userid: "Rodic-1", role: "Rodic")

    entry = store.fetch("u@example.com", "zsdemo")
    expect(entry[:session_id]).to eq("abc")
    expect(entry[:userid]).to eq("Rodic-1")
    expect(entry[:saved_at]).not_to be_nil
  end

  it "keeps schools of one account apart" do
    store.store("u@example.com", "zsdemo", session_id: "a")
    store.store("u@example.com", "zusdemo", session_id: "b")

    expect(store.all("u@example.com").keys).to contain_exactly("zsdemo", "zusdemo")
    expect(store.fetch("u@example.com", "zusdemo")[:session_id]).to eq("b")
  end

  it "returns nil for anything unknown" do
    expect(store.fetch("nobody", "nowhere")).to be_nil
    expect(store.all("nobody")).to eq({})
  end

  it "deletes one school and then the account" do
    store.store("u@example.com", "zsdemo", session_id: "a")
    store.store("u@example.com", "zusdemo", session_id: "b")

    store.delete("u@example.com", "zsdemo")
    expect(store.all("u@example.com").keys).to eq(["zusdemo"])

    store.delete("u@example.com")
    expect(store.all("u@example.com")).to eq({})
  end

  it "stores session ids in a file only the owner can read" do
    store.store("u@example.com", "zsdemo", session_id: "abc")

    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "starts over rather than failing when the file is corrupt" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{not json")

    expect(store.fetch("u@example.com", "zsdemo")).to be_nil
    expect { store.store("u@example.com", "zsdemo", session_id: "a") }.not_to raise_error
    expect(store.fetch("u@example.com", "zsdemo")[:session_id]).to eq("a")
  end

  it "shrinks the file when entries are removed" do
    store.store("u@example.com", "zsdemo", session_id: "a" * 200)
    big = File.size(path)
    store.delete("u@example.com")

    expect(File.size(path)).to be < big
    expect(File.read(path)).not_to include("a" * 200)
  end

  describe "#with_lock" do
    it "makes a second process wait for the first to finish" do
      # The cursor switch and the fetch that depends on it must not interleave with
      # another process, so this has to be a real file lock rather than a mutex.
      hold = 0.4
      ready_read, ready_write = IO.pipe

      pid = fork do
        ready_read.close
        store.with_lock do
          ready_write.write("locked")
          ready_write.close
          sleep hold
        end
        exit!(0)
      end

      ready_write.close
      expect(ready_read.read).to eq("locked")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      store.with_lock { :noop }
      waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      Process.wait(pid)

      expect(waited).to be > (hold / 2)
    end

    it "returns the block's value" do
      expect(store.with_lock { :ok }).to eq(:ok)
    end

    it "releases the lock when the block raises" do
      expect { store.with_lock { raise "boom" } }.to raise_error("boom")

      expect(Timeout.timeout(2) { store.with_lock { :recovered } }).to eq(:recovered)
    end
  end
end
