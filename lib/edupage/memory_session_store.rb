require "monitor"
require "time"

module Edupage
  # SessionStore kept in memory.
  #
  # The public server holds one per grant: Edupage session ids are never written to
  # disk and never shared between accounts. The lock is a reentrant Monitor instead of
  # a file lock, because only threads of this process can share the session.
  class MemorySessionStore
    def initialize
      @data = {}
      @monitor = Monitor.new
    end

    def fetch(username, origin)
      @monitor.synchronize do
        entry = @data.dig(username.to_s, origin.to_s)
        entry && entry[:session_id] ? entry.dup : nil
      end
    end

    def all(username)
      @monitor.synchronize { @data.fetch(username.to_s, {}).transform_values(&:dup) }
    end

    def store(username, origin, session_id:, userid: nil, role: nil, name: nil)
      @monitor.synchronize do
        (@data[username.to_s] ||= {})[origin.to_s] = {
          session_id: session_id, userid: userid, role: role, name: name,
          saved_at: Time.now.iso8601
        }
      end
    end

    # Removes one school's session, or every session for the user when origin is nil.
    def delete(username, origin = nil)
      @monitor.synchronize do
        if origin
          @data[username.to_s]&.delete(origin.to_s)
          @data.delete(username.to_s) if @data[username.to_s]&.empty?
        else
          @data.delete(username.to_s)
        end
      end
    end

    def clear
      @monitor.synchronize { @data.clear }
    end

    def with_lock(&)
      @monitor.synchronize(&)
    end

    def inspect = "#<Edupage::MemorySessionStore users=#{@data.size}>"
    alias to_s inspect
  end
end
