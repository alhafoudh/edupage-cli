RSpec.describe Edupage::Credentials do
  let(:env_class) { Edupage::Credentials::Adapters::Env }

  def creds(env: {}, system: nil, **kwargs)
    described_class.new(env: env_class.new(env), system: -> { system }, **kwargs)
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

  describe "the system credential store" do
    let(:store) do
      instance_double(Edupage::Credentials::Adapters::MacosKeychain,
                      source_for: "keychain", display_name: "macOS keychain")
    end

    it "is never touched when ENV supplies the password" do
      lookups = 0
      c = described_class.new(
        env: env_class.new("EDUPAGE_USERNAME" => "u", "EDUPAGE_PASSWORD" => "from-env"),
        system: -> { lookups += 1 }
      )

      expect(c.password).to eq("from-env")
      expect(c.password_source).to eq("ENV: EDUPAGE_PASSWORD")
      expect(c.username).to eq("u")
      c.school
      expect(c).to be_password_from_env
      expect(lookups).to eq(0)
    end

    it "is not consulted for username or school" do
      lookups = 0
      c = described_class.new(env: env_class.new({}), system: -> { lookups += 1 },
                              username: "flag", school: "flagschool")

      expect([c.username, c.school]).to eq(%w[flag flagschool])
      expect(lookups).to eq(0)
    end

    it "supplies the password when ENV has none" do
      allow(store).to receive(:password).with(username: "u").and_return("stored")
      c = creds(env: { "EDUPAGE_USERNAME" => "u" }, system: store)

      expect(c.password).to eq("stored")
      expect(c.password_source).to eq("keychain")
      expect(c).not_to be_password_from_env
    end

    it "is looked up once" do
      lookups = 0
      allow(store).to receive(:password).and_return("stored")
      c = described_class.new(env: env_class.new("EDUPAGE_USERNAME" => "u"),
                              system: -> { lookups += 1; store })

      c.password
      c.password_source

      expect(lookups).to eq(1)
    end
  end

  describe ".system_adapter" do
    let(:adapters) { described_class::SYSTEM_ADAPTERS }

    it "picks the first store available on this machine" do
      adapters.each { |a| allow(a).to receive(:available?).and_return(false) }
      allow(Edupage::Credentials::Adapters::SecretService).to receive(:available?).and_return(true)

      expect(described_class.system_adapter).to be_a(Edupage::Credentials::Adapters::SecretService)
    end

    it "is nil when there is none" do
      adapters.each { |a| allow(a).to receive(:available?).and_return(false) }

      expect(described_class.system_adapter).to be_nil
    end
  end

  describe "missing values" do
    it "raises a directive error for a missing username" do
      expect { creds.username }
        .to raise_error(Edupage::MissingCredentialsError, /--username|EDUPAGE_USERNAME/)
    end

    it "points at login and the store when the store has nothing" do
      store = instance_double(Edupage::Credentials::Adapters::WindowsCredentialManager,
                              password: nil, display_name: "Windows Credential Manager")

      expect { creds(env: { "EDUPAGE_USERNAME" => "u" }, system: store).password }
        .to raise_error(Edupage::MissingCredentialsError,
                        /edupage login.*Windows Credential Manager.*EDUPAGE_PASSWORD/)
    end

    it "points at EDUPAGE_PASSWORD when there is no store" do
      expect { creds(env: { "EDUPAGE_USERNAME" => "u" }).password }
        .to raise_error(Edupage::MissingCredentialsError, /no OS credential store.*EDUPAGE_PASSWORD/)
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
end
