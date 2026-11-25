RSpec.describe Edupage::WebLogin do
  subject(:login) { described_class.new(school: "zsdemo", username: "parent@example.com", password: "s3cret") }

  let(:base) { "https://zsdemo.edupage.org" }
  let(:ok_login) do
    { "status" => "OK", "edupage" => "zsdemo", "typ" => "Rodic", "id" => -1, "session" => "sid123",
      "meno" => "Ahmed", "priezvisko" => "Novák", "need2fa" => nil, "isTwoFactorLogged" => false }
  end

  def rpc_params(request)
    JSON.parse(URI.decode_www_form(request.body).to_h.fetch("rpcparams"))
  end

  def stub_get_token
    stub_request(:post, "#{base}/login/?cmd=MainLogin&akcia=getToken")
      .to_return(body: JSON.generate("token" => "tok"))
  end

  def stub_login(body, matcher = nil)
    stub = stub_request(:post, "#{base}/login/?cmd=MainLogin&akcia=login")
    stub = stub.with { |req| matcher.call(rpc_params(req)) } if matcher
    stub.to_return(body: JSON.generate(body))
  end

  def two_factor_page(devices)
    props = { "username" => "parent@example.com", "deviceNames" => devices, "email" => "p***@example.com",
              "edupage" => "zsdemo", "requestid" => "req1" }
    "<html><script>\nvar props = #{JSON.generate(props)};\nReactDOM.render(x);\n</script></html>"
  end

  describe "#start" do
    it "logs in without two-factor" do
      stub_get_token
      stub_login(ok_login, ->(p) { p["username"] == "parent@example.com" && p["password"] == "s3cret" && p["userToken"] == "tok" })

      result = login.start
      expect(result.status).to eq(:ok)
      expect(result.session_id).to eq("sid123")
      expect(result.role).to eq("Rodic")
      expect(result.name).to eq("Ahmed Novák")
    end

    it "reports a pending two-factor approval" do
      stub_get_token
      stub_login(ok_login.merge("need2fa" => "1", "redirectUrl" => "/login/twofactor?"))

      expect(login.start.status).to eq(:two_factor)
    end

    it "raises on a wrong password" do
      stub_get_token
      stub_login({ "status" => "fail", "err" => { "error_id" => "bad_password" } })

      expect { login.start }.to raise_error(Edupage::LoginError)
    end

    it "reads the obfuscated eqz: response form too" do
      stub_request(:post, "#{base}/login/?cmd=MainLogin&akcia=getToken")
        .to_return(body: "eqz:#{Base64.strict_encode64(JSON.generate("token" => "tok"))}")
      stub_login(ok_login)

      expect(login.start.status).to eq(:ok)
    end
  end

  describe "two-factor" do
    before do
      stub_get_token
      stub_login(ok_login.merge("need2fa" => "1"))
      login.start
    end

    it "recognises the push channel" do
      stub_request(:get, "#{base}/login/twofactor").to_return(body: two_factor_page(["iPhone"]))

      info = login.two_factor_info
      expect(info.channel).to eq(:push)
      expect(info.device_names).to eq(["iPhone"])
    end

    it "recognises the e-mail channel" do
      stub_request(:get, "#{base}/login/twofactor").to_return(body: two_factor_page([]))

      info = login.two_factor_info
      expect(info.channel).to eq(:email)
      expect(info.email).to eq("p***@example.com")
    end

    it "maps the poll answers" do
      stub_request(:post, "#{base}/login/twofactor?akcia=checkIfConfirmed")
        .to_return({ body: '{"status":"fail","data":[]}' },
                   { body: '{"status":"fail","data":{"requestexpired":true}}' },
                   { body: '{"status":"ok","data":"secret42"}' })

      expect([login.poll, login.poll, login.poll]).to eq([:waiting, :expired, "secret42"])
    end

    it "sends the e-mail code and reports throttling" do
      stub_request(:post, "#{base}/login/twofactor?akcia=sendEmail")
        .to_return({ body: '{"status":"ok","data":{"email":"p***@example.com"}}' },
                   { body: '{"status":"fail","data":{"retryInSeconds":42}}' })

      expect(login.send_email).to eq(:sent)
      expect(login.send_email).to eq(42)
    end

    it "re-sends the push" do
      stub_request(:post, "#{base}/login/twofactor?akcia=resendNotifs").to_return(body: '{"status":"ok"}')

      expect(login.resend_push).to be(true)
    end

    it "completes with the secret" do
      stub_login(ok_login.merge("isTwoFactorLogged" => true),
                 ->(p) { p["t2fasec"] == "secret42" && p["2fNoSave"] == "y" && p["2fform"] == "1" })

      result = login.complete("secret42")
      expect(result.status).to eq(:ok)
      expect(result.session_id).to eq("sid123")
    end

    it "raises on a wrong code" do
      stub_login({ "status" => "fail", "err" => { "error_id" => "invalid_token" } })

      expect { login.complete("000000") }.to raise_error(Edupage::LoginError)
    end
  end

  it "turns network failures and error statuses into LoginError" do
    stub_request(:post, "#{base}/login/?cmd=MainLogin&akcia=getToken").to_timeout
    expect { login.start }.to raise_error(Edupage::LoginError)

    stub_request(:post, "#{base}/login/?cmd=MainLogin&akcia=getToken").to_return(status: 502)
    expect { login.start }.to raise_error(Edupage::LoginError)
  end

  it "never shows the password" do
    expect(login.inspect).not_to include("s3cret")
  end
end
