require "mechanize"
require "json"

module Edupage
  # Raw HTTP against one Edupage origin.
  #
  # Redirects are deliberately NOT followed: an expired session answers a normal page
  # request with `302 -> /login/...`, which is the cheapest reliable way to notice.
  # Following it would instead yield a 40 KB login page that has to be sniffed for.
  #
  # Knows nothing about sessions or cursors; Session adds those on top.
  class Client
    USER_AGENT = "edupage-cli/#{VERSION} (+https://github.com/alhafoudh/edupage-cli)".freeze
    MAUTH_PATH = "/login/mauth".freeze

    # Mirrors the payload the official mobile client sends. Most fields are ignored by
    # the server but omitting them changes the response shape.
    MAUTH_PAYLOAD = {
      "plgc" => "", "ajheslo" => "1", "hasujheslo" => "1", "ajportal" => "1",
      "ajportallogin" => "1", "mobileLogin" => "1", "version" => "2020.0.18",
      "device_name" => "", "device_id" => "", "device_key" => "", "os" => "",
      "murl" => "", "edid" => ""
    }.freeze

    Response = Struct.new(:status, :body, :uri, keyword_init: true) do
      def ok? = status.between?(200, 299)

      # Both signals are verified against the live server: a dead session redirects
      # page requests to /login/, and answers portalping with the literal "notlogged".
      def expired?
        return true if status == 302 && location_is_login?
        return true if body.to_s.strip == "notlogged"

        false
      end

      def location_is_login? = uri.to_s.include?("/login/")

      def json = JSON.parse(body)
    end

    class << self
      # Exchanges credentials for one session per school the account can reach.
      #
      # A single login can span several schools (a parent with children at two
      # schools), and each entry carries its own esid - so this returns a list, not one
      # session.
      def mauth(school:, username:, password:)
        # The login server is the school's own subdomain; the generic "login1" host
        # rejects passwords for school-scoped accounts.
        agent = build_agent
        payload = MAUTH_PAYLOAD.merge(
          "m" => username, "h" => password,
          "edupage" => school.to_s, "fromEdupage" => school.to_s
        )

        page = agent.post("https://#{school}.edupage.org#{MAUTH_PATH}", payload)
        data = JSON.parse(page.body)

        users = data["users"] || []
        if users.empty?
          raise LoginError, data["needEdupage"] ? "Incorrect username" : "Incorrect password"
        end

        users.map do |user|
          {
            userid: user["userid"],
            first_name: user["first_name"] || user["firstname"],
            last_name: user["last_name"] || user["lastname"],
            origin: user["edupage"],
            session_id: user["esid"],
            role: user["typ"],
            needs_2fa: user["need2fa"].to_s == "1"
          }
        end
      rescue JSON::ParserError => e
        raise LoginError, "Login endpoint returned something that is not JSON: #{e.message}"
      end

      def build_agent
        Mechanize.new do |a|
          a.user_agent = USER_AGENT
          a.redirect_ok = false
          a.follow_meta_refresh = false
          # Pages are 200-400 KB of HTML but every parser here works on the embedded
          # <script> JSON via regex, so building a DOM would be pure waste.
          a.pluggable_parser.default = Mechanize::File
          a.pluggable_parser.html = Mechanize::File
          a.open_timeout = 15
          a.read_timeout = 60
        end
      end
    end

    attr_reader :origin
    attr_accessor :session_id

    def initialize(origin:, session_id: nil)
      @origin = origin
      @session_id = session_id
      @agent = self.class.build_agent
    end

    def base_url = "https://#{origin}.edupage.org"

    def get(path)
      request(:get, path)
    end

    def post(path, data = {})
      request(:post, path, data)
    end

    private

    def request(method, path, data = nil)
      url = path.start_with?("http") ? path : "#{base_url}#{path}"

      page =
        if method == :post
          @agent.post(url, data || {}, headers)
        else
          @agent.get(url, [], nil, headers)
        end

      Response.new(status: page.code.to_i, body: page.body, uri: response_location(page, url))
    rescue Mechanize::ResponseCodeError => e
      code = e.response_code.to_i
      # 3xx arrives here when Mechanize declines to follow it.
      return Response.new(status: code, body: e.page&.body.to_s, uri: response_location(e.page, url)) if code < 400

      raise RequestError, "#{method.to_s.upcase} #{path} failed with HTTP #{code}"
    rescue Mechanize::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
      raise RequestError, "#{method.to_s.upcase} #{path} failed: #{e.class}: #{e.message}"
    end

    def response_location(page, fallback)
      location = page&.response&.[]("location")
      location || fallback
    end

    def headers
      h = {
        "Accept" => "application/json, text/javascript, */*; q=0.01",
        "X-Requested-With" => "XMLHttpRequest",
        "Referer" => "#{base_url}/"
      }
      h["Cookie"] = "PHPSESSID=#{session_id}" if session_id
      h
    end
  end
end
