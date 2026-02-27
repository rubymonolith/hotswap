require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "hotswap"

FIXTURE_DIR = ENV.fetch("HOTSWAP_FIXTURE_DIR", File.expand_path("../../tmp/fixture", __dir__))
FileUtils.mkdir_p(File.join(FIXTURE_DIR, "config"))
FileUtils.mkdir_p(File.join(FIXTURE_DIR, "tmp"))

DB_PATH = ENV.fetch("HOTSWAP_DB_PATH", File.join(FIXTURE_DIR, "test.sqlite3"))
PORT = ENV.fetch("PORT", "9292").to_i

# Write database.yml so Rails AR railtie is happy
File.write(File.join(FIXTURE_DIR, "config", "database.yml"), <<~YAML)
  default: &default
    adapter: sqlite3
    database: #{DB_PATH}
  development:
    <<: *default
  test:
    <<: *default
  production:
    <<: *default
YAML

class FixtureApp < Rails::Application
  config.root = FIXTURE_DIR
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = false
  config.logger = Logger.new($stderr)
  config.log_level = ENV.fetch("LOG_LEVEL", "warn").to_sym
  config.active_support.deprecation = :silence
  config.secret_key_base = "test-secret-key-base-for-hotswap-specs"
  config.hosts.clear

  config.active_record.maintain_test_schema = false

  config.hotswap.database_path = DB_PATH
  config.hotswap.socket_path = File.join(FIXTURE_DIR, "sqlite3.sock")
  config.hotswap.stderr_socket_path = File.join(FIXTURE_DIR, "sqlite3.stderr.sock")
end

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

class Item < ApplicationRecord
end

class ItemsController < ActionController::API
  def index
    render json: Item.pluck(:name)
  end
end

class HealthController < ActionController::API
  def show
    render json: { status: "ok" }
  end
end

if __FILE__ == $0
  FixtureApp.initialize!

  FixtureApp.routes.draw do
    get "/items" => "items#index"
    get "/health" => "health#show"
  end

  # Create schema if needed
  unless ActiveRecord::Base.connection.table_exists?(:items)
    ActiveRecord::Schema.define do
      create_table :items do |t|
        t.string :name
      end
    end
  end

  require "rackup/handler/webrick"

  $stderr.puts "Hotswap fixture app listening on port #{PORT}"
  $stderr.puts "  DB: #{DB_PATH}"
  $stderr.puts "  Socket: #{Hotswap.socket_path}"
  Rackup::Handler::WEBrick.run(FixtureApp, Port: PORT, Logger: Logger.new("/dev/null"), AccessLog: [])
end
