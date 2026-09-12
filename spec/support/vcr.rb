require "vcr"
require "webmock/rspec"

# Values that must never reach a committed cassette. Anything matching is replaced
# with a placeholder at record time.
VCR.configure do |config|
  config.cassette_library_dir = File.expand_path("../cassettes", __dir__)
  config.hook_into :webmock
  config.configure_rspec_metadata!

  config.default_cassette_options = {
    record: ENV["VCR_RECORD"] ? ENV["VCR_RECORD"].to_sym : :none,
    match_requests_on: %i[method uri body]
  }

  # Session ids travel in both directions: Set-Cookie on login, Cookie on every
  # subsequent request.
  config.filter_sensitive_data("<PHPSESSID>") do |interaction|
    interaction.request.headers["Cookie"]&.first&.[](/PHPSESSID=([^;]+)/, 1)
  end
  config.filter_sensitive_data("<ESID>") do |interaction|
    interaction.response.headers["Set-Cookie"]&.first&.[](/PHPSESSID=([^;]+)/, 1)
  end

  # mauth carries the credentials in the POST body as m= and h=.
  config.filter_sensitive_data("<USERNAME>") { ENV["EDUPAGE_USERNAME"] }
  config.filter_sensitive_data("<PASSWORD>") { ENV["EDUPAGE_PASSWORD"] }
  config.filter_sensitive_data("<SCHOOL>") { ENV["EDUPAGE_SCHOOL"]&.sub(/\.edupage\.org\z/, "") }

  config.before_record do |interaction|
    body = interaction.request.body
    next if body.nil? || body.empty?

    interaction.request.body = body
      .gsub(/(\bm=)[^&]*/, '\1<USERNAME>')
      .gsub(/(\bh=)[^&]*/, '\1<PASSWORD>')
  end
end
