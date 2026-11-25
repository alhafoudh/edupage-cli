RSpec.describe Edupage::Client, ".mauth" do
  it "raises BadCredentialsError for a wrong password, still a LoginError" do
    stub_request(:post, "https://zsdemo.edupage.org/login/mauth").to_return(body: JSON.generate("users" => []))

    expect { described_class.mauth(school: "zsdemo", username: "u", password: "nope") }
      .to raise_error(Edupage::BadCredentialsError, "Incorrect password")
    expect(Edupage::BadCredentialsError.ancestors).to include(Edupage::LoginError)
  end

  it "turns a network failure into an Edupage error" do
    stub_request(:post, "https://zsdemo.edupage.org/login/mauth").to_timeout

    expect { described_class.mauth(school: "zsdemo", username: "u", password: "p") }
      .to raise_error(Edupage::RequestError)
  end

  it "reports an unknown school as NotFoundError" do
    stub_request(:post, "https://zsnope.edupage.org/login/mauth").to_return(status: 404)

    expect { described_class.mauth(school: "zsnope", username: "u", password: "p") }
      .to raise_error(Edupage::NotFoundError, /zsnope/)
  end

  it "turns an HTTP error status into an Edupage error" do
    stub_request(:post, "https://zsdemo.edupage.org/login/mauth").to_return(status: 503)

    expect { described_class.mauth(school: "zsdemo", username: "u", password: "p") }
      .to raise_error(Edupage::RequestError)
  end

  it "keeps an unreadable answer a plain LoginError" do
    stub_request(:post, "https://zsdemo.edupage.org/login/mauth").to_return(body: "<html>")

    expect { described_class.mauth(school: "zsdemo", username: "u", password: "nope") }
      .to raise_error(Edupage::LoginError) { |e| expect(e).not_to be_a(Edupage::BadCredentialsError) }
  end
end
