module Hotswap
  class Middleware
    SWAP_LOCK = Mutex.new

    def initialize(app)
      @app = app
    end

    def call(env)
      SWAP_LOCK.synchronize { @app.call(env) }
    end
  end
end
