module Edupage
  module Server
    module Public
      # Failed-login counters held in memory, so the login form cannot be used to guess
      # Edupage passwords. Keys are the client IP and "username|school".
      class RateLimiter
        def initialize(limit: 5, window: 900, clock: -> { Time.now.to_i })
          @limit = limit
          @window = window
          @clock = clock
          @failures = Hash.new { |hash, key| hash[key] = [] }
          @lock = Mutex.new
        end

        def now = @clock.call

        def blocked?(*keys)
          @lock.synchronize { keys.any? { |key| recent(key).size >= @limit } }
        end

        def failure!(*keys)
          @lock.synchronize { keys.each { |key| recent(key) << now } }
        end

        def reset!(*keys)
          @lock.synchronize { keys.each { |key| @failures.delete(key) } }
        end

        private

        def recent(key)
          @failures[key].select! { |at| at > now - @window }
          @failures[key]
        end
      end
    end
  end
end
