module Hotswap
  class Railtie < Rails::Railtie
    config.hotswap = ActiveSupport::OrderedOptions.new

    initializer "hotswap.logger" do
      Hotswap.logger = Rails.logger
    end

    initializer "hotswap.configure" do |app|
      # Discover all SQLite databases from Rails config
      if app.config.hotswap.database_paths
        Array(app.config.hotswap.database_paths).each { |p| Hotswap.register(p) }
      elsif app.config.hotswap.database_path
        Hotswap.register(app.config.hotswap.database_path)
      else
        db_configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
        db_configs.each do |db_config|
          if db_config.adapter.include?("sqlite")
            Hotswap.register(db_config.database)
          end
        end
      end

      # Socket paths
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
