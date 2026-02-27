module Hotswap
  class Railtie < Rails::Railtie
    config.hotswap = ActiveSupport::OrderedOptions.new

    initializer "hotswap.configure" do |app|
      # Default database path from Rails config
      if app.config.hotswap.database_path
        Hotswap.database_path = app.config.hotswap.database_path
      else
        db_config = app.config.database_configuration[Rails.env]
        if db_config && db_config["adapter"]&.include?("sqlite")
          Hotswap.database_path = db_config["database"]
        end
      end

      # Default socket paths
      if app.config.hotswap.socket_path
        Hotswap.socket_path = app.config.hotswap.socket_path
      else
        Hotswap.socket_path = File.join(app.root, "tmp", "sockets", "hotswap.sock")
      end

      if app.config.hotswap.stderr_socket_path
        Hotswap.stderr_socket_path = app.config.hotswap.stderr_socket_path
      else
        Hotswap.stderr_socket_path = File.join(app.root, "tmp", "sockets", "hotswap.stderr.sock")
      end
    end

    initializer "hotswap.middleware" do |app|
      app.middleware.use Hotswap::Middleware
    end

    server do
      server = Hotswap::SocketServer.new
      server.start

      at_exit { server.stop }
    end
  end
end
