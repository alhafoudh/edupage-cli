require "fileutils"

module Edupage
  module Server
    module Public
      # One live Account per grant, kept in this process.
      #
      # The account is built from the Edupage sessions sealed in the grant; there is no
      # password, so nothing here ever logs in. An expired session surfaces as
      # SessionExpiredError and the user reconnects.
      #
      # Each grant gets its own in-memory session store, its own cache directory and its
      # own mutex. Every call of a grant runs under that mutex: Edupage keeps the current
      # child and year in the session, so two parallel tool calls on one account would
      # otherwise read each other's cursor. Different grants never share anything.
      class Runtimes
        Entry = Struct.new(:account, :mutex, :last_used, keyword_init: true)

        GRANT_ID = /\A\h{32}\z/

        def initialize(data_dir:, idle: 1800, clock: -> { Time.now.to_i }, account_builder: nil)
          @data_dir = data_dir
          @idle = idle
          @clock = clock
          @account_builder = account_builder || method(:build_account)
          @entries = {}
          @lock = Mutex.new
        end

        def with_account(grant_id, credentials)
          current = @lock.synchronize { @entries[grant_id] ||= Entry.new(mutex: Mutex.new) }
          current.mutex.synchronize do
            current.account ||= @account_builder.call(grant_id, credentials)
            current.last_used = @clock.call
            yield current.account
          end
        end

        # Idle runtimes are dropped; the next call rebuilds them from the grant.
        def evict_idle!(now = @clock.call)
          @lock.synchronize do
            @entries.delete_if { |_, e| !e.mutex.locked? && e.last_used && e.last_used <= now - @idle }
          end
        end

        def forget(grant_id)
          @lock.synchronize { @entries.delete(grant_id) }
          FileUtils.rm_rf(cache_root(grant_id))
        end

        def cache_root(grant_id)
          # The id ends up in a path; anything but our own hex ids is refused.
          raise ArgumentError, "invalid grant id" unless grant_id.to_s.match?(GRANT_ID)

          File.join(@data_dir, "cache", grant_id.to_s)
        end

        def inspect = "#<#{self.class.name} size=#{@entries.size}>"

        private

        def build_account(grant_id, credentials)
          username = credentials[:username]
          static = StaticCredentials.new(username: username, password: nil, school: credentials[:school])
          store = MemorySessionStore.new
          sessions = Hash(credentials[:sessions]).map do |origin, stored|
            Session.new(origin: origin.to_s, username: username, session_id: stored[:session_id],
                        credentials: static, userid: stored[:userid], role: stored[:role],
                        name: stored[:name], store: store)
          end
          Account.new(username: username, sessions: sessions, credentials: static, store: store,
                      cache: Cache.new(root: cache_root(grant_id)))
        end
      end
    end
  end
end
