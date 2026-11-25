require "base64"
require "json"
require "mechanize"

module Edupage
  # The browser login of an Edupage school, including two-factor approval.
  #
  # The mobile endpoint (Client.mauth) only reports that a school wants a second
  # factor. Completing it goes through the web login, as decoded from a browser
  # capture on 2026-11-25:
  #
  #   1. MainLogin getToken, then login           -> session id, need2fa
  #   2. GET /login/twofactor                     -> deviceNames, masked e-mail
  #   3. push: poll checkIfConfirmed until it returns the secret
  #      e-mail: sendEmail, the user types the code
  #   4. MainLogin login again with t2fasec        -> the same session id, now usable
  #
  # Only an interactive login can do this, so it lives in the public server's login
  # form and never runs during a data request.
  class WebLogin
    Result = Struct.new(:status, :session_id, :userid, :role, :name, keyword_init: true) do
      def inspect = "#<WebLogin::Result status=#{status.inspect} role=#{role.inspect}>"
      alias_method :to_s, :inspect
    end

    TwoFactorInfo = Struct.new(:device_names, :email, :channel, keyword_init: true)

    LOGIN_PATH = "/login/?cmd=MainLogin".freeze
    TWO_FACTOR_PATH = "/login/twofactor".freeze

    attr_reader :school, :username, :session_id

    def initialize(school:, username:, password:, agent: nil)
      @school = school.to_s
      @username = username
      @password = password
      @agent = agent || Client.build_agent
      @session_id = nil
    end

    def base_url = "https://#{school}.edupage.org"

    def start
      token = rpc(LOGIN_PATH, "getToken", "username" => username, "edupage" => school)["token"]
      raise LoginError, "Edupage did not hand out a login token for #{school}" if token.to_s.empty?

      response = rpc(LOGIN_PATH, "login",
                     "username" => username, "password" => @password, "userToken" => token,
                     "edupage" => school, "ctxt" => "", "tu" => nil, "gu" => nil, "au" => nil)
      result_from(response)
    end

    def two_factor_info
      page = transport { @agent.get("#{base_url}#{TWO_FACTOR_PATH}", [], nil, headers) }
      props = parse_props(page.body.to_s)
      devices = Array(props["deviceNames"]).map(&:to_s)
      TwoFactorInfo.new(device_names: devices, email: props["email"].to_s,
                        channel: devices.empty? ? :email : :push)
    end

    # :waiting until the user approves in the app, :expired when the request timed out,
    # otherwise the secret to pass to #complete.
    def poll
      response = rpc("#{TWO_FACTOR_PATH}?akcia=checkIfConfirmed", nil, {})
      return response["data"].to_s if response["status"].to_s.casecmp?("ok")
      return :expired if response["data"].is_a?(Hash) && response["data"]["requestexpired"]

      :waiting
    end

    # :sent, or the number of seconds Edupage wants us to wait before asking again.
    def send_email
      response = plain_post("#{TWO_FACTOR_PATH}?akcia=sendEmail")
      return :sent if response["status"].to_s.casecmp?("ok")

      retry_in = response["data"].is_a?(Hash) && response["data"]["retryInSeconds"]
      return retry_in.to_i if retry_in

      raise LoginError, "Edupage refused to send a two-factor code by e-mail"
    end

    def resend_push
      plain_post("#{TWO_FACTOR_PATH}?akcia=resendNotifs")["status"].to_s.casecmp?("ok")
    end

    def complete(secret)
      response = rpc(LOGIN_PATH, "login",
                     "t2fasec" => secret.to_s, "2fNoSave" => "y", "2fform" => "1",
                     "tu" => nil, "gu" => nil, "au" => nil)
      result = result_from(response)
      raise LoginError, "Edupage did not accept the two-factor confirmation" unless result.status == :ok

      result
    end

    def inspect = "#<Edupage::WebLogin school=#{school.inspect} username=#{username.inspect}>"
    alias to_s inspect

    private

    def result_from(response)
      unless response["status"].to_s.casecmp?("ok")
        error = response.dig("err", "error_id") || response["error"] || "login failed"
        raise LoginError, "Edupage login for #{school} failed: #{error}"
      end

      self.session_id = response["session"] if response["session"]
      Result.new(
        status: response["need2fa"].to_s == "1" ? :two_factor : :ok,
        session_id: session_id,
        userid: [response["typ"], response["id"]].compact.join(""),
        role: response["typ"],
        name: [response["meno"], response["priezvisko"]].compact.join(" ")
      )
    end

    def session_id=(value)
      @session_id = value
      cookie = HTTP::Cookie.new("PHPSESSID", value, domain: "#{school}.edupage.org", path: "/")
      @agent.cookie_jar.add(cookie)
    end

    # Edupage's AscHttp.rpc: form field rpcparams with JSON. Responses may come back
    # obfuscated as eqz:<base64>.
    def rpc(path, action, params)
      url = action ? "#{base_url}#{path}&akcia=#{action}" : "#{base_url}#{path}"
      page = transport { @agent.post(url, { "rpcparams" => JSON.generate(params) }, headers) }
      decode(page.body.to_s)
    end

    def plain_post(path)
      decode(transport { @agent.post("#{base_url}#{path}", {}, headers) }.body.to_s)
    end

    # Everything that can go wrong talking to Edupage surfaces as LoginError, so the
    # login form can show it instead of failing.
    def transport
      yield
    rescue Mechanize::ResponseCodeError => e
      raise LoginError, "Edupage login for #{school} failed with HTTP #{e.response_code}"
    rescue *Client::TRANSPORT_ERRORS => e
      raise LoginError, "Edupage login for #{school} failed: #{e.class}"
    end

    def decode(body)
      text = body.start_with?("eqz:") ? Base64.decode64(body[4..]) : body
      JSON.parse(text.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError
      raise LoginError, "Edupage login answered with something that is not JSON"
    end

    def headers
      { "X-Requested-With" => "XMLHttpRequest", "Accept" => "application/json, text/javascript, */*" }
    end

    def parse_props(html)
      line = html.lines.find { |l| l.lstrip.start_with?("var props = ") }
      raise LoginError, "Two-factor page of #{school} has an unexpected shape" unless line

      JSON.parse(line.strip.delete_prefix("var props = ").delete_suffix(";"))
    rescue JSON::ParserError
      raise LoginError, "Two-factor page of #{school} has an unexpected shape"
    end
  end
end
