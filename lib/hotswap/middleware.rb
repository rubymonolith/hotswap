module Hotswap
  class Middleware
    SWAP_LOCK = Mutex.new

    def initialize(app)
      @app = app
    end

    def call(env)
      if SWAP_LOCK.locked?
        logger.info "request queued, waiting for swap to complete: #{env['REQUEST_METHOD']} #{env['PATH_INFO']}"
        SWAP_LOCK.synchronize do
          logger.info "swap complete, resuming request: #{env['REQUEST_METHOD']} #{env['PATH_INFO']}"
          @app.call(env)
        end
      else
        SWAP_LOCK.synchronize { @app.call(env) }
      end
    end

    private

    def logger = Hotswap.logger
  end
end
