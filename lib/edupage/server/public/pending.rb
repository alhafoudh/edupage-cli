require "securerandom"

module Edupage
  module Server
    module Public
      # Authorization requests in progress: the OAuth parameters plus whatever the login
      # form has gathered so far (credentials, sessions, the running two-factor login).
      # Memory only; a restart simply makes the user start again from the client.
      class Pending
        Auth = Struct.new(:id, :csrf, :oauth, :credentials, :sessions, :queue, :skipped, :current,
                          :info, :created_at, :lock, :two_factor_total, :password, keyword_init: true) do
          def synchronize(&) = lock.synchronize(&)

          def inspect = "#<Pending::Auth id=#{id.inspect} queue=#{queue.inspect}>"
          alias_method :to_s, :inspect
        end

        def initialize(ttl: 600, clock: -> { Time.now.to_i })
          @ttl = ttl
          @clock = clock
          @entries = {}
          @lock = Mutex.new
        end

        def now = @clock.call

        def create(oauth)
          auth = Auth.new(id: SecureRandom.urlsafe_base64(24), csrf: SecureRandom.urlsafe_base64(24),
                          oauth: oauth, credentials: nil, sessions: {}, queue: [], skipped: [],
                          current: nil, info: nil, created_at: now, lock: Monitor.new)
          @lock.synchronize do
            sweep!
            @entries[auth.id] = auth
          end
          auth
        end

        def find(id)
          @lock.synchronize do
            sweep!
            @entries[id.to_s]
          end
        end

        def delete(id)
          @lock.synchronize { @entries.delete(id.to_s) }
        end

        def expire!
          @lock.synchronize { sweep! }
        end

        private

        def sweep!
          @entries.delete_if { |_, auth| auth.created_at <= now - @ttl }
        end

        public

        def inspect = "#<#{self.class.name} size=#{@entries.size}>"
      end
    end
  end
end
