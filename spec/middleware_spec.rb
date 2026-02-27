require "spec_helper"

RSpec.describe Hotswap::Middleware do
  include Rack::Test::Methods

  let(:inner_app) { ->(env) { [200, {"content-type" => "text/plain"}, ["hello"]] } }
  let(:app) { Hotswap::Middleware.new(inner_app) }

  it "passes requests through to the app" do
    response = app.call(Rack::MockRequest.env_for("/"))
    expect(response[0]).to eq(200)
    expect(response[2]).to eq(["hello"])
  end

  it "holds requests while SWAP_LOCK is held" do
    results = []

    # Hold the lock in another thread
    Hotswap::Middleware::SWAP_LOCK.lock
    t = Thread.new do
      response = app.call(Rack::MockRequest.env_for("/"))
      results << response[0]
    end

    sleep 0.05
    expect(results).to be_empty

    Hotswap::Middleware::SWAP_LOCK.unlock
    t.join(2)

    expect(results).to eq([200])
  end
end
