require_relative "hotswap/version"
require_relative "hotswap/middleware"
require_relative "hotswap/cli"
require_relative "hotswap/socket_server"
require_relative "hotswap/railtie" if defined?(Rails::Railtie)

module Hotswap
  class Error < StandardError; end

  class << self
    attr_accessor :database_path, :socket_path, :stderr_socket_path

    def configure
      yield self
    end
  end

  self.socket_path = "tmp/hotswap.sock"
  self.stderr_socket_path = "tmp/hotswap.stderr.sock"
end
