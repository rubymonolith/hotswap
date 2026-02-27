require_relative "hotswap/version"
require_relative "hotswap/middleware"
require_relative "hotswap/database"
require_relative "hotswap/cli"
require_relative "hotswap/socket_server"
require_relative "hotswap/railtie" if defined?(Rails::Railtie)

module Hotswap
  class Error < StandardError; end

  class << self
    attr_accessor :socket_path, :stderr_socket_path

    def configure
      yield self
    end

    # Registry of managed databases
    def databases
      @databases ||= []
    end

    def register(path)
      db = Database.new(path)
      databases << db unless databases.any? { |d| d.path == db.path }
      db
    end

    def find_database(path)
      return nil if path == "-"
      resolved = File.expand_path(path)
      databases.find { |db| db.path == resolved }
    end

    # Backward compat: single database_path getter/setter
    def database_path=(path)
      @databases = []
      register(path) if path
    end

    def database_path
      databases.first&.path
    end
  end

  self.socket_path = "tmp/sockets/hotswap.sock"
  self.stderr_socket_path = "tmp/sockets/hotswap.stderr.sock"
end
