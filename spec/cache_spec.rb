RSpec.describe Edupage::Cache do
  subject(:cache) { described_class.new(root: root) }

  let(:root) { File.join(Edupage::Config.cache_dir, "spec") }

  it "computes on a miss and reads back on a hit" do
    calls = 0
    value = -> { calls += 1; { "a" => 1 } }

    expect(cache.fetch("zsdemo", "2026", "-77", "user", &value)).to eq("a" => 1)
    expect(cache.fetch("zsdemo", "2026", "-77", "user", &value)).to eq("a" => 1)
    expect(calls).to eq(1)
  end

  it "keys on school, year and child so they never share an entry" do
    cache.fetch("zsdemo", "2026", "-77", "user") { { "who" => "peter" } }
    cache.fetch("zsdemo", "2026", "113506", "user") { { "who" => "jana" } }
    cache.fetch("zsdemo", "2025", "-77", "user") { { "who" => "peter-2025" } }

    expect(cache.fetch("zsdemo", "2026", "-77", "user") { raise }).to eq("who" => "peter")
    expect(cache.fetch("zsdemo", "2026", "113506", "user") { raise }).to eq("who" => "jana")
    expect(cache.fetch("zsdemo", "2025", "-77", "user") { raise }).to eq("who" => "peter-2025")
  end

  it "expires an entry once its TTL passes" do
    cache.fetch("s", "2026", "c", "doc", kind: :document) { { "v" => 1 } }
    path = cache.path_for(%w[s 2026 c doc])
    File.utime(Time.now - 7200, Time.now - 7200, path)

    expect(cache.fetch("s", "2026", "c", "doc", kind: :document) { { "v" => 2 } }).to eq("v" => 2)
  end

  it "keeps data from a closed year indefinitely" do
    cache.fetch("s", "2020", "c", "znamky", immutable: true) { { "v" => 1 } }
    path = cache.path_for(%w[s 2020 c znamky])
    File.utime(Time.now - (86_400 * 365), Time.now - (86_400 * 365), path)

    expect(cache.fetch("s", "2020", "c", "znamky", immutable: true) { { "v" => 2 } }).to eq("v" => 1)
  end

  it "recomputes rather than failing when a file is corrupt" do
    cache.fetch("s", "2026", "c", "doc") { { "v" => 1 } }
    File.write(cache.path_for(%w[s 2026 c doc]), "{not json")

    expect(cache.fetch("s", "2026", "c", "doc") { { "v" => 2 } }).to eq("v" => 2)
  end

  it "never writes when disabled" do
    disabled = described_class.new(root: root, enabled: false)
    calls = 0

    2.times { disabled.fetch("s", "2026", "c", "doc") { calls += 1; { "v" => 1 } } }

    expect(calls).to eq(2)
    expect(disabled.entries).to be_empty
  end

  it "makes negative ids and hostnames safe as path segments" do
    path = cache.path_for(["zsdemo.edupage.org", "2026", "-77", "user"])

    expect(path).to include("zsdemo.edupage.org", "-77")
    expect(File.basename(path)).to eq("user.json")
  end

  it "clears everything" do
    cache.fetch("s", "2026", "c", "doc") { { "v" => 1 } }
    expect(cache.entries).not_to be_empty

    cache.clear
    expect(cache.entries).to be_empty
  end

  it "leaves no temporary files behind" do
    cache.fetch("s", "2026", "c", "doc") { { "v" => 1 } }

    expect(Dir.glob(File.join(root, "**", "*.tmp"))).to be_empty
  end
end
