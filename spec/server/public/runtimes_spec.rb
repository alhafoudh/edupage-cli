RSpec.describe Edupage::Server::Public::Runtimes do
  subject(:runtimes) { described_class.new(data_dir: data_dir, idle: 1800, clock: -> { now }, account_builder: builder) }

  let(:g1) { "1" * 32 }
  let(:g2) { "2" * 32 }
  let(:data_dir) { Edupage::Config.cache_dir }
  let(:now) { 1000 }
  let(:built) { [] }
  let(:builder) do
    lambda do |grant_id, credentials|
      built << [grant_id, credentials[:username]]
      Object.new
    end
  end
  let(:credentials) do
    { username: "u", school: "zsdemo", schools: ["zsdemo"], two_factor_origins: [],
      sessions: { zsdemo: { session_id: "sid", userid: "Rodic-1", role: "Rodic", name: "A B" } } }
  end

  it "builds one account per grant and reuses it" do
    first = runtimes.with_account(g1, credentials) { |account| account }
    second = runtimes.with_account(g1, credentials) { |account| account }

    expect(first).to be(second)
    expect(built.size).to eq(1)
  end

  it "serializes calls of one grant" do
    events = Queue.new
    threads = 2.times.map do |i|
      Thread.new do
        runtimes.with_account(g1, credentials) do
          events << [:enter, i]
          sleep 0.05
          events << [:exit, i]
        end
      end
    end
    threads.each(&:join)
    order = Array.new(events.size) { events.pop }

    expect(order.map(&:first)).to eq(%i[enter exit enter exit])
  end

  it "keeps grants apart, cache included" do
    runtimes.with_account(g1, credentials) { nil }
    runtimes.with_account(g2, credentials.merge(username: "other")) { nil }

    expect(built.map(&:first)).to eq([g1, g2])
    expect(runtimes.cache_root(g1)).to eq(File.join(data_dir, "cache", g1))
    expect(runtimes.cache_root(g1)).not_to eq(runtimes.cache_root(g2))
  end

  it "evicts idle runtimes, rebuilds them on demand and forgets their cache" do
    runtimes.with_account(g1, credentials) { nil }
    FileUtils.mkdir_p(runtimes.cache_root(g1))
    runtimes.evict_idle!(now + 1801)
    runtimes.with_account(g1, credentials) { nil }

    expect(built.size).to eq(2)

    runtimes.forget(g1)
    expect(Dir.exist?(runtimes.cache_root(g1))).to be(false)
  end

  it "refuses to build a cache path from a strange grant id" do
    expect { runtimes.cache_root("../etc") }.to raise_error(ArgumentError)
  end

  context "with the default builder" do
    subject(:runtimes) { described_class.new(data_dir: data_dir) }

    it "uses the stored sessions without logging in" do
      expect(Edupage::Client).not_to receive(:mauth)
      expect(Edupage).not_to receive(:account)

      account = runtimes.with_account(g1, credentials) { |acc| acc }
      expect(account.username).to eq("u")
      expect(account.schools.map(&:origin)).to eq(["zsdemo"])
      expect(Dir.glob(File.join(Edupage::Config.cache_dir, "sessions.json"))).to be_empty
    end

    it "reports an expired session instead of logging in again" do
      expect(Edupage::Client).not_to receive(:mauth)
      stub_request(:any, /zsdemo\.edupage\.org/)
        .to_return(status: 302, headers: { "Location" => "https://zsdemo.edupage.org/login/" })

      expect do
        runtimes.with_account(g1, credentials) { |acc| acc.school("zsdemo").students.to_a }
      end.to raise_error(Edupage::SessionExpiredError)
    end
  end
end
