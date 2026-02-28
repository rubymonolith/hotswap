require "active_record"
require "hotswap"
require "rack/test"
require "tempfile"
require "fileutils"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random

  config.before do
    allow(ActiveRecord::Base.connection_handler).to receive(:clear_all_connections!)
    allow(ActiveRecord::Base).to receive(:establish_connection)
  end
end
