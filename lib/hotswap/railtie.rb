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

      # Socket path
      if app.config.hotswap.socket_path
        Hotswap.socket_path = app.config.hotswap.socket_path
      else
        Hotswap.socket_path = File.join(app.root, "tmp", "sockets", "hotswap.sock")
      end
    end

    initializer "hotswap.middleware" do |app|
      app.middleware.use Hotswap::Middleware
    end

    server do
      server = Thor::Socket::Server.new(
        Hotswap::CLI,
        socket_path: Hotswap.socket_path,
        logger: Hotswap.logger
      )
      server.start

      Hotswap.logger.info "managing #{Hotswap.databases.size} database(s): #{Hotswap.databases.map(&:path).join(', ')}"

      at_exit { server.stop }
    end
  end
end
