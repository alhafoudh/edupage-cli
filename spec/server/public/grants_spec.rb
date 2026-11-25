RSpec.describe Edupage::Server::Public::Grants do
  subject(:grants) { described_class.new(store: store, pepper: pepper, clock: -> { now }) }

  let(:store) { Edupage::Server::Public::Store.new(File.join(Edupage::Config.cache_dir, "g.sqlite3")) }
  let(:pepper) { "p" * 32 }
  let(:now) { 1_000_000 }
  let(:crypto) { Edupage::Server::Public::Crypto }
  let(:verifier) { "v" * 50 }
  let(:challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }
  let(:credentials) do
    { username: "parent@example.com", password: "s3cret", school: "zsdemo",
      schools: %w[zsdemo], two_factor_origins: [] }
  end

  def issue
    grants.issue_code(client_id: "c1", credentials: credentials, redirect_uri: "https://claude.ai/cb",
                      code_challenge: challenge, resource: "https://mcp.example.com/mcp")
  end

  def exchange(code, **overrides)
    grants.exchange_code(code, **{ client_id: "c1", redirect_uri: "https://claude.ai/cb",
                                   code_verifier: verifier }.merge(overrides))
  end

  it "runs the whole cycle back to the original credentials" do
    grant_id, code = issue
    tokens = exchange(code)

    unlocked = grants.unlock(tokens.access_token)
    expect(unlocked.grant_id).to eq(grant_id)
    expect(unlocked.credentials).to eq(credentials)
    expect(tokens.expires_in).to eq(3600)
  end

  describe "code exchange" do
    it "refuses a wrong verifier" do
      _, code = issue
      expect { exchange(code, code_verifier: "w" * 50) }.to raise_error(described_class::InvalidGrant)
    end

    it "refuses a wrong redirect URI" do
      _, code = issue
      expect { exchange(code, redirect_uri: "https://evil.example/cb") }.to raise_error(described_class::InvalidGrant)
    end

    it "refuses another client" do
      _, code = issue
      expect { exchange(code, client_id: "c2") }.to raise_error(described_class::InvalidGrant)
    end

    it "refuses an expired code" do
      _, code = issue
      allow(grants).to receive(:now).and_return(now + 61)
      expect { exchange(code) }.to raise_error(described_class::InvalidGrant)
    end

    it "treats a second use as an attack and drops the grant" do
      grant_id, code = issue
      tokens = exchange(code)

      expect { exchange(code) }.to raise_error(described_class::InvalidGrant)
      expect { grants.unlock(tokens.access_token) }.to raise_error(described_class::InvalidToken)
      expect(store.find_grant(grant_id)).to be_nil
    end
  end

  describe "refresh" do
    it "rotates both tokens" do
      _, code = issue
      first = exchange(code)
      second = grants.refresh(first.refresh_token, client_id: "c1")

      expect(grants.unlock(second.access_token).credentials).to eq(credentials)
      expect { grants.unlock(first.access_token) }.to raise_error(described_class::InvalidToken)
    end

    it "revokes everything when an old refresh token comes back after the grace period" do
      _, code = issue
      first = exchange(code)
      second = grants.refresh(first.refresh_token, client_id: "c1")
      allow(grants).to receive(:now).and_return(now + 61)

      expect { grants.refresh(first.refresh_token, client_id: "c1") }.to raise_error(described_class::InvalidGrant)
      expect { grants.unlock(second.access_token) }.to raise_error(described_class::InvalidToken)
    end

    it "refuses another client" do
      _, code = issue
      first = exchange(code)

      expect { grants.refresh(first.refresh_token, client_id: "c2") }.to raise_error(described_class::InvalidGrant)
    end

    it "does not drop the grant when a client refreshes twice within a minute" do
      grant_id, code = issue
      first = exchange(code)
      second = grants.refresh(first.refresh_token, client_id: "c1")
      allow(grants).to receive(:now).and_return(now + 30)

      expect { grants.refresh(first.refresh_token, client_id: "c1") }.to raise_error(described_class::InvalidGrant)
      expect(store.find_grant(grant_id)).not_to be_nil
      expect(grants.unlock(second.access_token).credentials).to eq(credentials)
    end

    it "drops the grant when an old refresh token comes back later" do
      grant_id, code = issue
      first = exchange(code)
      grants.refresh(first.refresh_token, client_id: "c1")
      allow(grants).to receive(:now).and_return(now + 61)

      expect { grants.refresh(first.refresh_token, client_id: "c1") }.to raise_error(described_class::InvalidGrant)
      expect(store.find_grant(grant_id)).to be_nil
    end

    it "forgets the wrapped key of a token once it is used" do
      _, code = issue
      first = exchange(code)
      grants.refresh(first.refresh_token, client_id: "c1")
      _, id, = crypto.parse_token(first.refresh_token)
      _, code_id, = crypto.parse_token(code)

      expect(store.find_token(id)[:wrapped_key]).to be_nil
      expect(store.find_token(code_id)[:wrapped_key]).to be_nil
    end

    it "lets only one of two concurrent uses of a refresh token through" do
      grant_id, code = issue
      first = exchange(code)
      # The other request marks the token used between our lookup and our transaction.
      allow(grants).to receive(:authenticate).and_wrap_original do |original, *args|
        original.call(*args).tap { |row, _| store.mark_token_used(row[:id], now) }
      end

      expect { grants.refresh(first.refresh_token, client_id: "c1") }.to raise_error(described_class::InvalidGrant)
      # Within the grace period the loser only fails; the grant survives.
      expect(store.find_grant(grant_id)).not_to be_nil
    end
  end

  it "accepts a token that arrives as binary, the way Puma hands over headers" do
    _, code = issue
    tokens = exchange(code)

    expect(grants.unlock(tokens.access_token.b).credentials).to eq(credentials)
  end

  it "expires access tokens after an hour" do
    _, code = issue
    tokens = exchange(code)
    allow(grants).to receive(:now).and_return(now + 3601)

    expect { grants.unlock(tokens.access_token) }.to raise_error(described_class::InvalidToken)
  end

  it "refuses a token with the right id but a wrong secret" do
    _, code = issue
    tokens = exchange(code)
    _, id, = crypto.parse_token(tokens.access_token)
    forged = "ea_#{id}.#{crypto.generate_token("ea")[1]}"

    expect { grants.unlock(forged) }.to raise_error(described_class::InvalidToken)
  end

  it "reports every deleted grant, whatever deleted it" do
    deleted = []
    watched = described_class.new(store: store, pepper: pepper, clock: -> { now }, on_delete: ->(id) { deleted << id })
    revoked_id, code = watched.issue_code(client_id: "c1", credentials: credentials, redirect_uri: "https://claude.ai/cb",
                                          code_challenge: challenge, resource: "r")
    watched.revoke(watched.exchange_code(code, client_id: "c1", redirect_uri: "https://claude.ai/cb",
                                               code_verifier: verifier).access_token)
    replayed_id, code = watched.issue_code(client_id: "c1", credentials: credentials, redirect_uri: "https://claude.ai/cb",
                                           code_challenge: challenge, resource: "r")
    watched.exchange_code(code, client_id: "c1", redirect_uri: "https://claude.ai/cb", code_verifier: verifier)
    expect do
      watched.exchange_code(code, client_id: "c1", redirect_uri: "https://claude.ai/cb", code_verifier: verifier)
    end.to raise_error(described_class::InvalidGrant)

    expect(deleted).to eq([revoked_id, replayed_id])
  end

  it "revokes a grant by any of its tokens" do
    grant_id, code = issue
    tokens = exchange(code)
    grants.revoke(tokens.refresh_token)

    expect(store.find_grant(grant_id)).to be_nil
    expect { grants.revoke("garbage") }.not_to raise_error
  end

  it "cannot be decrypted from the database alone, even with the pepper" do
    grant_id, code = issue
    exchange(code)
    db = SQLite3::Database.new(store_path = File.join(Edupage::Config.cache_dir, "g.sqlite3"))
    db.results_as_hash = true
    token_rows = db.execute("SELECT * FROM tokens WHERE grant_id = ?", [grant_id])
    sealed = db.execute("SELECT sealed_credentials FROM grants WHERE id = ?", [grant_id]).first["sealed_credentials"]

    expect(token_rows).not_to be_empty
    token_rows.each do |row|
      guess = crypto.derive_key(pepper: pepper, secret: row["secret_hash"])
      expect { crypto.open(guess, row["wrapped_key"], aad: "#{grant_id}:#{row["id"]}") }
        .to raise_error(crypto::DecryptError)
    end
    expect(File.read(store_path, mode: "rb")).not_to include("s3cret")
    expect { crypto.open(crypto.derive_key(pepper: pepper, secret: ""), sealed, aad: grant_id) }
      .to raise_error(crypto::DecryptError)
  ensure
    db&.close
  end

  it "cleans up grants unused for 90 days" do
    grant_id, code = issue
    exchange(code)

    expect(grants.cleanup!(now + (90 * 86_400) + 1)).to eq([grant_id])
    expect(store.find_grant(grant_id)).to be_nil
  end

  it "keeps inspect free of secrets" do
    expect(grants.inspect).not_to include(pepper)
  end
end
