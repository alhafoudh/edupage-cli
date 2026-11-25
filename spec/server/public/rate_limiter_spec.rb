RSpec.describe Edupage::Server::Public::RateLimiter do
  subject(:limiter) { described_class.new(limit: 5, window: 900, clock: -> { now }) }

  let(:now) { 1000 }

  it "blocks after five failures on any key" do
    5.times { limiter.failure!("1.2.3.4", "u|s") }

    expect(limiter.blocked?("1.2.3.4")).to be(true)
    expect(limiter.blocked?("9.9.9.9", "u|s")).to be(true)
    expect(limiter.blocked?("9.9.9.9", "other|s")).to be(false)
  end

  it "forgets failures outside the window" do
    5.times { limiter.failure!("ip") }
    allow(limiter).to receive(:now).and_return(now + 901)

    expect(limiter.blocked?("ip")).to be(false)
  end

  it "resets keys on success" do
    4.times { limiter.failure!("ip") }
    limiter.reset!("ip")
    limiter.failure!("ip")

    expect(limiter.blocked?("ip")).to be(false)
  end
end
