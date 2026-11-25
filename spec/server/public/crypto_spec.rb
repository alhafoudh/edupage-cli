RSpec.describe Edupage::Server::Public::Crypto do
  let(:key) { described_class.random_key }

  describe "seal / open" do
    it "round-trips" do
      sealed = described_class.seal(key, "hello", aad: "g1")

      expect(described_class.open(key, sealed, aad: "g1")).to eq("hello")
    end

    it "refuses the wrong key" do
      sealed = described_class.seal(key, "hello", aad: "g1")

      expect { described_class.open(described_class.random_key, sealed, aad: "g1") }
        .to raise_error(described_class::DecryptError)
    end

    it "refuses the wrong associated data" do
      sealed = described_class.seal(key, "hello", aad: "g1")

      expect { described_class.open(key, sealed, aad: "g2") }.to raise_error(described_class::DecryptError)
    end

    it "refuses a tampered ciphertext" do
      raw = Base64.strict_decode64(described_class.seal(key, "hello", aad: "g1"))
      raw.setbyte(raw.bytesize - 1, raw.getbyte(raw.bytesize - 1) ^ 1)

      expect { described_class.open(key, Base64.strict_encode64(raw), aad: "g1") }
        .to raise_error(described_class::DecryptError)
    end

    it "refuses garbage" do
      expect { described_class.open(key, "not base64 at all!", aad: "g1") }
        .to raise_error(described_class::DecryptError)
    end
  end

  describe ".derive_key" do
    it "is deterministic and depends on the pepper" do
      a = described_class.derive_key(pepper: "p" * 32, secret: "s")

      expect(described_class.derive_key(pepper: "p" * 32, secret: "s")).to eq(a)
      expect(described_class.derive_key(pepper: "q" * 32, secret: "s")).not_to eq(a)
      expect(a.bytesize).to eq(32)
    end
  end

  describe "tokens" do
    it "parses what it generates" do
      id, secret, string = described_class.generate_token("ea")

      expect(string).to eq("ea_#{id}.#{secret}")
      expect(described_class.parse_token(string)).to eq(["ea", id, secret])
    end

    it "rejects malformed tokens" do
      expect(described_class.parse_token("ea_x")).to be_nil
      expect(described_class.parse_token(nil)).to be_nil
      expect(described_class.parse_token("zz_#{"a" * 32}.abc")).to be_nil
    end

    it "digests and compares in constant time" do
      expect(described_class.digest("abc")).to eq(Digest::SHA256.hexdigest("abc"))
      expect(described_class.secure_equal?("abc", "abc")).to be(true)
      expect(described_class.secure_equal?("abc", "abd")).to be(false)
      expect(described_class.secure_equal?("abc", "ab")).to be(false)
    end
  end
end
