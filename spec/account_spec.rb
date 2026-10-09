RSpec.describe Edupage::Account do
  describe ".login" do
    let(:username) { "u@example.com" }
    let(:credentials) do
      instance_double(Edupage::Credentials, username: username, password: "hunter2", school: "zsdemo")
    end
    let(:store) { Edupage::SessionStore.new(path: File.join(Edupage::Config.cache_dir, "sessions.json")) }

    def stored(origin, session_id)
      store.store(username, origin, session_id: session_id, userid: "Rodic-1", role: "Rodic", name: "A B")
    end

    def mauth_entry(origin, session_id)
      { userid: "Rodic-1", origin: origin, session_id: session_id, role: "Rodic",
        first_name: "A", last_name: "B" }
    end

    # A stored session is alive unless its id says otherwise.
    before do
      allow_any_instance_of(Edupage::Session).to receive(:valid?) { |session| session.session_id != "dead" }
      stored("zsdemo", "alive")
      stored("zsother", "dead")
    end

    it "renews a dead school session instead of dropping the school" do
      allow(Edupage::Client).to receive(:mauth).with(school: "zsother", username: username, password: "hunter2")
                                               .and_return([mauth_entry("zsother", "fresh")])

      account = described_class.login(credentials: credentials, store: store)

      expect(account.schools.map(&:origin)).to contain_exactly("zsdemo", "zsother")
      expect(store.fetch(username, "zsother")[:session_id]).to eq("fresh")
      expect(store.fetch(username, "zsdemo")[:session_id]).to eq("alive")
    end

    it "drops and forgets a school the account can no longer reach" do
      allow(Edupage::Client).to receive(:mauth).and_return([mauth_entry("zsdemo", "fresh")])

      account = described_class.login(credentials: credentials, store: store)

      expect(account.schools.map(&:origin)).to eq(["zsdemo"])
      expect(store.fetch(username, "zsother")).to be_nil
    end

    it "keeps a school behind two-factor approval listed without failing the login" do
      allow(Edupage::Client).to receive(:mauth)
        .and_return([mauth_entry("zsother", "half").merge(needs_2fa: true)])

      account = described_class.login(credentials: credentials, store: store)

      expect(account.schools.map(&:origin)).to contain_exactly("zsdemo", "zsother")
    end

    it "lets a wrong password surface" do
      allow(Edupage::Client).to receive(:mauth).and_raise(Edupage::LoginError, "Incorrect password")

      expect { described_class.login(credentials: credentials, store: store) }
        .to raise_error(Edupage::LoginError, /Incorrect password/)
    end
  end
end
