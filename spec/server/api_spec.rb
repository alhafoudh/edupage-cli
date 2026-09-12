require "rack/test"
require "edupage/server/api"

RSpec.describe Edupage::Server::API do
  include Rack::Test::Methods

  def app = described_class

  let(:token) { Edupage.config.server_token }
  let(:account) do
    Edupage::Account.new(
      username: "parent@example.com",
      sessions: [FakeSession.new],
      credentials: instance_double(Edupage::Credentials),
      cache: Edupage::Cache.new(enabled: false)
    )
  end

  before do
    described_class.account_options = {}
    described_class.mcp_server = nil
    allow(Edupage).to receive(:account).and_return(account)
  end

  def authorize! = header("Authorization", "Bearer #{token}")
  def body = JSON.parse(last_response.body)

  describe "authentication" do
    it "lets the health check through" do
      get "/healthz"

      expect(last_response.status).to eq(200)
      expect(body).to include("status" => "ok")
    end

    it "refuses a request with no token" do
      get "/api/v1/schools"

      expect(last_response.status).to eq(401)
      expect(body["error"]).to match(/Unauthorized/)
    end

    it "refuses a wrong token" do
      header("Authorization", "Bearer nope")
      get "/api/v1/schools"

      expect(last_response.status).to eq(401)
    end

    it "accepts the token as a query parameter too" do
      get "/api/v1/schools", token: token

      expect(last_response.status).to eq(200)
    end
  end

  describe "resources" do
    before { authorize! }

    it "serves an account-scoped resource" do
      get "/api/v1/schools"

      expect(last_response.status).to eq(200)
      expect(body["data"].first).to include("origin" => "zsdemo")
      expect(body["meta"]).to include("resource" => "schools", "count" => 1)
    end

    it "serves a school-scoped resource" do
      get "/api/v1/schools/zsdemo/subjects"

      expect(body["data"].map { |s| s["short"] }).to contain_exactly("SJL", "MAT")
    end

    it "serves a student-scoped resource, resolving the student by name" do
      get "/api/v1/schools/zsdemo/students/Jana/lessons"

      expect(last_response.status).to eq(200)
      expect(body["data"]).to all(include("subject"))
    end

    it "serves a year-scoped resource" do
      get "/api/v1/schools/zsdemo/students/Jana/years/2025/grades"

      expect(last_response.status).to eq(200)
      expect(body["meta"]["resource"]).to eq("grades")
    end

    it "applies declared filters from the query string" do
      get "/api/v1/schools/zsdemo/subjects", name: "MAT"

      expect(body["data"].map { |s| s["short"] }).to eq(["MAT"])
    end
  end

  describe "errors" do
    before { authorize! }

    it "answers 404 for a student that does not exist" do
      get "/api/v1/schools/zsdemo/students/Nobody/lessons"

      expect(last_response.status).to eq(404)
      expect(body["error"]).to match(/No student/)
    end

    it "answers 404 for an unknown school" do
      get "/api/v1/schools/nosuchschool/subjects"

      expect(last_response.status).to eq(404)
    end
  end

  describe "read-only surface" do
    it "exposes no write verbs outside /mcp" do
      authorize!

      post "/api/v1/schools"
      expect(last_response.status).to eq(404)

      delete "/api/v1/schools/zsdemo/subjects"
      expect(last_response.status).to eq(404)
    end
  end
end
