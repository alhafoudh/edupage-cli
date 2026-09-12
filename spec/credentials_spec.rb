RSpec.describe Edupage::Credentials do
  let(:env_class) { Edupage::Credentials::Env }

  def creds(env: {}, keychain: nil, **kwargs)
    providers = [env_class.new(env)]
    providers << keychain if keychain
    described_class.new(providers: providers, **kwargs)
  end

  describe "resolution order" do
    it "prefers ENV over every other source" do
      config = Edupage::Config.new({ "default_username" => "cfg", "default_school" => "cfgschool" })
      c = creds(env: { "EDUPAGE_USERNAME" => "env", "EDUPAGE_SCHOOL" => "envschool" },
                username: "flag", school: "flagschool", config: config)

      expect(c.username).to eq("env")
      expect(c.school).to eq("envschool")
      expect(c.username_source).to eq("ENV: EDUPAGE_USERNAME")
    end

    it "falls back to explicit overrides, then config" do
      config = Edupage::Config.new({ "default_username" => "cfg", "default_school" => "cfgschool" })

      flagged = creds(username: "flag", school: "flagschool", config: config)
      expect(flagged.username).to eq("flag")
      expect(flagged.username_source).to eq("--username")

      configured = creds(config: config)
      expect(configured.username).to eq("cfg")
      expect(configured.username_source).to eq("config")
    end

    it "strips the .edupage.org suffix from the school" do
      expect(creds(env: { "EDUPAGE_SCHOOL" => "zsdemo.edupage.org" }).school).to eq("zsdemo")
    end
  end

  describe "missing values" do
    it "raises a directive error for a missing username" do
      expect { creds.username }
        .to raise_error(Edupage::MissingCredentialsError, /--username|EDUPAGE_USERNAME/)
    end

    it "raises a directive error for a missing password" do
      expect { creds(env: { "EDUPAGE_USERNAME" => "u" }).password }
        .to raise_error(Edupage::MissingCredentialsError, /EDUPAGE_PASSWORD/)
    end
  end

  describe "secrecy" do
    it "keeps the password out of inspect and to_s" do
      c = creds(env: { "EDUPAGE_USERNAME" => "u", "EDUPAGE_PASSWORD" => "hunter2" })

      expect(c.inspect).not_to include("hunter2")
      expect(c.to_s).not_to include("hunter2")
      expect(c.inspect).to include("u")
    end
  end

  describe "#password_shadowed?" do
    let(:keychain) { instance_double(Edupage::Credentials::Keychain) }

    before do
      allow(keychain).to receive_messages(username: nil, school: nil, source_for: "keychain")
    end

    it "is true when ENV hides a stored keychain password" do
      allow(keychain).to receive(:password).with(username: "u").and_return("stored")
      c = creds(env: { "EDUPAGE_USERNAME" => "u", "EDUPAGE_PASSWORD" => "from-env" }, keychain: keychain)

      expect(c.password).to eq("from-env")
      expect(c).to be_password_shadowed
    end

    it "is false when ENV supplies a password and the keychain has none" do
      allow(keychain).to receive(:password).and_return(nil)
      c = creds(env: { "EDUPAGE_USERNAME" => "u", "EDUPAGE_PASSWORD" => "from-env" }, keychain: keychain)

      expect(c).not_to be_password_shadowed
    end

    it "is false when the keychain is the source" do
      allow(keychain).to receive(:password).with(username: "u").and_return("stored")
      c = creds(env: { "EDUPAGE_USERNAME" => "u" }, keychain: keychain)

      expect(c.password).to eq("stored")
      expect(c.password_source).to eq("keychain")
      expect(c).not_to be_password_shadowed
    end
  end
end
