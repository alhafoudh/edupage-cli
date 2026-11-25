require "rack/test"

RSpec.describe Edupage::Server::Public::RequestLog do
  include Rack::Test::Methods

  let(:io) { StringIO.new }
  let(:inner) { ->(_env) { [200, { "content-type" => "text/plain" }, ["ok"]] } }
  let(:app) { described_class.new(inner) }

  before { Edupage.logger = Logger.new(io, level: Logger::INFO) }
  after { Edupage.logger = nil }

  it "logs method, path, status and duration without query or body" do
    header "Authorization", "Bearer ea_secret"
    post "/oauth/token?code=x", "password=hunter2&code_verifier=abc"

    line = io.string
    expect(line).to match(%r{POST /oauth/token 200 \d+ms})
    expect(line).not_to include("code=x")
    expect(line).not_to include("hunter2")
    expect(line).not_to include("ea_secret")
  end

  context "when the app names what it did" do
    let(:inner) do
      lambda do |env|
        env[described_class::DETAIL] = "tools/call edupage_grades"
        [200, {}, ["ok"]]
      end
    end

    it "appends it to the line" do
      post "/mcp"

      expect(io.string).to match(%r{POST /mcp 200 \d+ms tools/call edupage_grades$})
    end
  end
end
