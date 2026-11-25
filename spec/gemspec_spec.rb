RSpec.describe "edupage-cli.gemspec" do
  let(:spec) { Gem::Specification.load(File.expand_path("../edupage-cli.gemspec", __dir__)) }

  # The Docker image installs the built gem, so anything left out of it is missing in
  # production even though every spec passes from the checkout.
  it "packages the public server's page templates" do
    templates = Dir.glob("lib/edupage/server/public/views/*.erb", base: File.expand_path("..", __dir__))

    expect(templates).not_to be_empty
    expect(spec.files).to include(*templates)
  end

  it "packages the icon the servers announce" do
    expect(spec.files).to include("lib/edupage/server/public/assets/favicon.ico")
  end
end
