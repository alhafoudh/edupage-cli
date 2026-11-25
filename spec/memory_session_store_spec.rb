RSpec.describe Edupage::MemorySessionStore do
  subject(:store) { described_class.new }

  it "round-trips like SessionStore" do
    store.store("u", "zsdemo", session_id: "abc", userid: "Rodic-1", role: "Rodic", name: "A")

    expect(store.fetch("u", "zsdemo")).to include(session_id: "abc", role: "Rodic")
    expect(store.all("u").keys).to eq(["zsdemo"])
  end

  it "deletes one origin or the whole user" do
    store.store("u", "a", session_id: "1")
    store.store("u", "b", session_id: "2")

    store.delete("u", "a")
    expect(store.all("u").keys).to eq(["b"])

    store.delete("u")
    expect(store.all("u")).to eq({})
  end

  it "has a reentrant lock" do
    expect(store.with_lock { store.with_lock { :ok } }).to eq(:ok)
  end

  it "never writes to disk" do
    store.store("u", "a", session_id: "1")

    expect(Dir.glob(File.join(Edupage::Config.cache_dir, "**", "*"))).to be_empty
  end

  it "hides session ids in inspect" do
    store.store("u", "a", session_id: "secretsid")

    expect(store.inspect).not_to include("secretsid")
  end

  it "lets Account.login keep sessions in memory with static credentials" do
    allow(Edupage::Client).to receive(:mauth).and_return(
      [{ origin: "zsdemo", session_id: "sid1", userid: "Rodic-1", role: "Rodic",
         first_name: "A", last_name: "B", needs_2fa: false }]
    )
    expect(Edupage::Credentials).not_to receive(:new)

    account = Edupage::Account.login(
      credentials: Edupage::StaticCredentials.new(username: "u", password: "p", school: "zsdemo"),
      store: store, cache: Edupage::Cache.new(enabled: false)
    )

    expect(account.username).to eq("u")
    expect(store.fetch("u", "zsdemo")).to include(session_id: "sid1")
  end
end
