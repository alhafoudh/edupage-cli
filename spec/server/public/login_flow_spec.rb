RSpec.describe Edupage::Server::Public::LoginFlow do
  subject(:flow) do
    described_class.new(pending: pending, rate_limiter: limiter, grants: grants,
                        issuer: "https://mcp.example.com", mauth: mauth, web_login: web_login_factory)
  end

  let(:now) { 1000 }
  let(:pending) { Edupage::Server::Public::Pending.new(ttl: 600, clock: -> { now }) }
  let(:limiter) { Edupage::Server::Public::RateLimiter.new(limit: 5, window: 900, clock: -> { now }) }
  let(:grants) { instance_double(Edupage::Server::Public::Grants) }
  let(:web_login) { instance_double(Edupage::WebLogin) }
  let(:web_login_factory) { ->(**_) { web_login } }
  let(:entries) { [entry("zsdemo")] }
  let(:mauth) do
    lambda do |school:, username:, password:|
      raise Edupage::BadCredentialsError, "Incorrect password" unless password == "right"

      entries
    end
  end

  let(:auth) do
    pending.create(client_id: "c1", redirect_uri: "https://claude.ai/cb?x=1", state: "st",
                   code_challenge: "ch", resource: "https://mcp.example.com/mcp", client_name: "Claude")
  end

  def entry(origin, two_factor: false)
    { origin: origin, session_id: "sid-#{origin}", userid: "Rodic-1", role: "Rodic",
      first_name: "A", last_name: "B", needs_2fa: two_factor }
  end

  def submit(password = "right", ip: "1.2.3.4")
    flow.submit_password(auth, school: "zsdemo", username: "Parent@example.com", password: password, ip: ip)
  end

  before do
    allow(grants).to receive(:issue_code).and_return(["grant1", "ec_code"])
  end

  describe "password step" do
    it "refuses a wrong password and counts it" do
      expect { submit("wrong") }.to raise_error(described_class::BadCredentials)
      expect(limiter).not_to be_blocked("1.2.3.4")
    end

    it "blocks after five failures even with the right password" do
      5.times { expect { submit("wrong") }.to raise_error(described_class::BadCredentials) }

      expect { submit("right") }.to raise_error(described_class::Blocked)
    end

    it "finishes straight away without two-factor" do
      expect(submit).to eq(:done)

      url = URI(flow.finish(auth))
      query = URI.decode_www_form(url.query).to_h
      expect(url.host).to eq("claude.ai")
      expect(query).to eq("x" => "1", "code" => "ec_code", "state" => "st", "iss" => "https://mcp.example.com")
      expect(grants).to have_received(:issue_code).with(
        client_id: "c1", redirect_uri: "https://claude.ai/cb?x=1", code_challenge: "ch",
        resource: "https://mcp.example.com/mcp",
        credentials: { username: "Parent@example.com", school: "zsdemo", schools: ["zsdemo"],
                       two_factor_origins: [],
                       sessions: { "zsdemo" => { session_id: "sid-zsdemo", userid: "Rodic-1", role: "Rodic",
                                                 name: "A B" } } }
      )
    end

    it "never hands the password to the grant" do
      submit
      flow.finish(auth)

      expect(grants).to have_received(:issue_code) { |args| expect(args.to_s).not_to include("right") }
      expect(auth.credentials).not_to have_key(:password)
    end

    it "refuses anything but a school subdomain before contacting anyone" do
      ["10.0.0.5:8443/x#", "zs demo", "evil.example/?", "", "a" * 64].each do |school|
        expect do
          flow.submit_password(auth, school: school, username: "u", password: "right", ip: "1.2.3.4")
        end.to raise_error(described_class::InvalidSchool)
      end
      expect { flow.submit_password(auth, school: "ZSDemo.edupage.org", username: "u", password: "right", ip: "ip") }
        .not_to raise_error
    end

    it "does not count an Edupage outage as a wrong password" do
      outage = ->(**) { raise Edupage::LoginError, "Login endpoint returned something that is not JSON" }
      down = described_class.new(pending: pending, rate_limiter: limiter, grants: grants,
                                 issuer: "https://mcp.example.com", mauth: outage)

      6.times do
        expect { down.submit_password(auth, school: "zsdemo", username: "u", password: "x", ip: "ip") }
          .to raise_error(Edupage::LoginError) { |e| expect(e).not_to be_a(described_class::BadCredentials) }
      end
      expect(limiter).not_to be_blocked("ip")
    end

    it "issues only one grant when the login finishes twice" do
      submit
      flow.finish(auth)

      expect { flow.finish(auth) }.to raise_error(described_class::Finished)
      expect(grants).to have_received(:issue_code).once
    end

    it "forgets the pending login once finished" do
      submit
      flow.finish(auth)

      expect(pending.find(auth.id)).to be_nil
    end
  end

  describe "two-factor" do
    let(:entries) { [entry("zsdemo"), entry("zsother", two_factor: true)] }
    let(:info) { Edupage::WebLogin::TwoFactorInfo.new(device_names: ["iPhone"], email: "p***", channel: :push) }
    let(:ok) { Edupage::WebLogin::Result.new(status: :ok, session_id: "sid-2fa", userid: "Rodic-1", role: "Rodic", name: "A B") }

    before do
      allow(web_login).to receive_messages(
        start: Edupage::WebLogin::Result.new(status: :two_factor, session_id: "sid-2fa"),
        two_factor_info: info
      )
    end

    it "waits for the app approval and then finishes" do
      expect(submit).to eq(:two_factor)
      expect(flow.current_two_factor(auth)).to eq(info)

      allow(web_login).to receive(:poll).and_return(:waiting, "secret")
      allow(web_login).to receive(:complete).with("secret").and_return(ok)

      expect(flow.poll(auth)).to eq(:waiting)
      expect(flow.poll(auth)).to eq(:done)

      flow.finish(auth)
      expect(grants).to have_received(:issue_code)
        .with(hash_including(credentials: hash_including(
          schools: %w[zsdemo zsother], two_factor_origins: [],
          sessions: hash_including("zsother" => hash_including(session_id: "sid-2fa"))
        )))
    end

    it "keeps the pending login usable when Edupage fails to start the two-factor step" do
      allow(web_login).to receive(:start).and_raise(Edupage::LoginError, "boom")
      submit

      expect { flow.current_two_factor(auth) }.to raise_error(Edupage::LoginError)
      expect(pending.find(auth.id)).not_to be_nil
      expect(auth.queue).to eq(["zsother"])
    end

    it "sends the e-mail right away when there is no device" do
      allow(web_login).to receive(:two_factor_info)
        .and_return(Edupage::WebLogin::TwoFactorInfo.new(device_names: [], email: "p***", channel: :email))
      allow(web_login).to receive(:send_email).and_return(:sent)
      submit

      flow.current_two_factor(auth)
      expect(web_login).to have_received(:send_email).once
    end

    it "accepts a typed code and reports a wrong one" do
      submit
      flow.current_two_factor(auth)
      allow(web_login).to receive(:complete).with("000000").and_raise(Edupage::LoginError, "nope")
      allow(web_login).to receive(:complete).with("123456").and_return(ok)

      expect(flow.submit_code(auth, "000000")).to eq(:invalid)
      expect(flow.submit_code(auth, "123456")).to eq(:done)
    end

    context "with several two-factor schools" do
      let(:entries) { [entry("zsa", two_factor: true), entry("zsb", two_factor: true), entry("zsc", two_factor: true)] }

      it "walks through them in order and reports the progress" do
        allow(web_login).to receive(:complete).and_return(ok)
        submit

        steps = []
        3.times do
          flow.current_two_factor(auth)
          steps << flow.progress(auth)
          flow.submit_code(auth, "123456")
        end

        expect(steps).to eq([["zsa", 1, 3], ["zsb", 2, 3], ["zsc", 3, 3]])
        expect(auth.sessions.keys).to eq(%w[zsa zsb zsc])
      end
    end

    it "lets the user skip a school and marks it unavailable" do
      submit
      expect(flow.skip(auth)).to eq(:done)

      flow.finish(auth)
      expect(grants).to have_received(:issue_code)
        .with(hash_including(credentials: hash_including(two_factor_origins: ["zsother"])))
    end

    context "when every school needs two-factor" do
      let(:entries) { [entry("zsother", two_factor: true)] }

      it "refuses to connect nothing" do
        submit
        flow.skip(auth)

        expect { flow.finish(auth) }.to raise_error(described_class::NothingUsable)
      end
    end
  end

  it "drops pending logins after ten minutes" do
    id = auth.id
    allow(pending).to receive(:now).and_return(now + 601)

    expect(pending.find(id)).to be_nil
  end

  it "keeps the password out of inspect" do
    submit
    expect(auth.inspect).not_to include("right")
  end
end
