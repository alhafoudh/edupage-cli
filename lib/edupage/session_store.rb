require "fileutils"
require "json"
require "time"

module Edupage
  # Persists one Edupage session id per (username, school) so consecutive commands
  # reuse a session instead of logging in again.
  #
  # The file holds live session ids, so it is created 0600 and every read-modify-write
  # runs under an exclusive flock - `edupage server` and a CLI invocation routinely run
  # at the same time.
  class SessionStore
    FILENAME = "sessions.json".freeze

    attr_reader :path

    def initialize(path: self.class.default_path)
      @path = path
    end

    def self.default_path
      File.join(Config.cache_dir, FILENAME)
    end

    def fetch(username, origin)
      data = read
      entry = data.dig(username.to_s, origin.to_s)
      return nil unless entry && entry["session_id"]

      symbolize(entry)
    end

    def all(username)
      read.fetch(username.to_s, {}).transform_values { |e| symbolize(e) }
    end

    def store(username, origin, session_id:, userid: nil, role: nil, name: nil)
      transaction do |data|
        data[username.to_s] ||= {}
        data[username.to_s][origin.to_s] = {
          "session_id" => session_id,
          "userid" => userid,
          "role" => role,
          "name" => name,
          "saved_at" => Time.now.iso8601
        }.compact
      end
    end

    # Removes one school's session, or every session for the user when origin is nil.
    def delete(username, origin = nil)
      transaction do |data|
        if origin
          data[username.to_s]&.delete(origin.to_s)
          data.delete(username.to_s) if data[username.to_s]&.empty?
        else
          data.delete(username.to_s)
        end
      end
    end

    def clear
      transaction { |data| data.clear }
    end

    # Exclusive advisory lock used by Session#with_cursor. The server-side cursors
    # (current child, current year) are global to a session, so two processes sharing a
    # session must not interleave a switch with someone else's fetch.
    def with_lock
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        begin
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    def lock_path = "#{path}.lock"

    private

    def read
      return {} unless File.exist?(path)

      # UTF-8 explicitly: the stored display name can contain diacritics, and a process
      # started without LANG would otherwise read it as US-ASCII and fail to parse.
      content = File.read(path, encoding: Encoding::UTF_8)
      return {} if content.strip.empty?

      JSON.parse(content)
    rescue JSON::ParserError
      # A truncated file is a cache, not a source of truth - start over rather than
      # making every command fail.
      Edupage.logger.warn("Discarding unreadable session store at #{path}")
      {}
    end

    def transaction
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.set_encoding(Encoding::UTF_8)
        file.flock(File::LOCK_EX)
        begin
          raw = file.read
          data = raw.strip.empty? ? {} : (JSON.parse(raw) rescue {})
          yield data
          file.rewind
          file.write(JSON.pretty_generate(data))
          file.flush
          file.truncate(file.pos)
          data
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    def symbolize(entry)
      {
        session_id: entry["session_id"],
        userid: entry["userid"],
        role: entry["role"],
        name: entry["name"],
        saved_at: entry["saved_at"]
      }
    end
  end
end
