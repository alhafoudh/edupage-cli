RSpec.describe Edupage::Server::Public::Store do
  subject(:store) { described_class.new(path) }

  let(:path) { File.join(Edupage::Config.cache_dir, "public", "edupage.sqlite3") }

  def grant(id = "g1")
    { id: id, client_id: "c1", sealed_credentials: "sealed", created_at: 100, last_used_at: 100 }
  end

  def token(id, grant_id: "g1", kind: "access", expires_at: 200)
    { id: id, grant_id: grant_id, kind: kind, secret_hash: "h-#{id}", wrapped_key: "w-#{id}",
      expires_at: expires_at, used_at: nil, extra: nil }
  end

  it "stores clients" do
    store.insert_client("c1", { "client_name" => "Claude" })

    expect(store.find_client("c1")).to eq(id: "c1", metadata: { "client_name" => "Claude" })
    expect(store.find_client("nope")).to be_nil
  end

  it "stores and touches grants" do
    store.insert_grant(grant)
    store.touch_grant("g1", 150)

    expect(store.find_grant("g1")).to include(client_id: "c1", sealed_credentials: "sealed", last_used_at: 150)
  end

  it "stores tokens with extra data and marks them used" do
    store.insert_grant(grant)
    store.insert_token(token("t1", kind: "code").merge(extra: { "redirect_uri" => "https://x/cb" }))
    store.mark_token_used("t1", 120)

    expect(store.find_token("t1")).to include(kind: "code", used_at: 120, extra: { "redirect_uri" => "https://x/cb" })
  end

  it "deletes tokens of one kind" do
    store.insert_grant(grant)
    store.insert_token(token("a1"))
    store.insert_token(token("r1", kind: "refresh"))
    store.delete_tokens("g1", kind: "access")

    expect(store.find_token("a1")).to be_nil
    expect(store.find_token("r1")).not_to be_nil
  end

  it "cascades grant deletion to its tokens" do
    store.insert_grant(grant)
    store.insert_token(token("t1"))
    store.delete_grant("g1")

    expect(store.find_grant("g1")).to be_nil
    expect(store.find_token("t1")).to be_nil
  end

  it "finds stale grants and expired tokens" do
    store.insert_grant(grant("old"))
    store.insert_grant(grant("new").merge(last_used_at: 500))
    store.insert_token(token("t1", grant_id: "new", expires_at: 10))
    store.insert_token(token("t2", grant_id: "new", expires_at: 1000))

    expect(store.expired_grant_ids(200)).to eq(["old"])
    store.delete_expired_tokens(100)
    expect(store.find_token("t1")).to be_nil
    expect(store.find_token("t2")).not_to be_nil
  end

  it "rolls a transaction back on error" do
    expect do
      store.transaction do
        store.insert_grant(grant)
        raise "boom"
      end
    end.to raise_error("boom")

    expect(store.find_grant("g1")).to be_nil
  end

  it "creates the database readable by the owner only", posix: true do
    store

    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end
end
