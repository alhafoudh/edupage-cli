RSpec.describe Edupage::StaticCredentials do
  subject(:creds) { described_class.new(username: "p@example.com", password: "s3cret", school: "zsdemo") }

  it "exposes the values" do
    expect([creds.username, creds.password, creds.school]).to eq(["p@example.com", "s3cret", "zsdemo"])
  end

  it "refuses to log in again without a password" do
    without = described_class.new(username: "p@example.com", password: nil, school: "zsdemo")

    expect { without.password }.to raise_error(Edupage::SessionExpiredError)
  end

  it "never shows the password" do
    expect([creds.inspect, creds.to_s, creds.to_h.to_s].join).not_to include("s3cret")
  end
end
