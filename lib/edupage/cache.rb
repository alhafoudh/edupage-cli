require "fileutils"
require "json"
require "time"

module Edupage
  # File-backed cache for parsed Edupage payloads.
  #
  # Fetching is expensive in a way that matters here: one dashboard is ~375 KB and a
  # single CLI invocation needs it before it can answer anything. Caching the parsed
  # payload keyed by (school, year, child, resource) makes consecutive commands cheap.
  #
  # The year is part of the key because Edupage's directory changes between years - the
  # class list for 2025 is genuinely different from 2026's - and the child is part of it
  # because timetables are per-child.
  #
  # Anything from a finished school year never changes, so it is kept indefinitely;
  # everything else gets a short TTL.
  class Cache
    FOREVER = Float::INFINITY

    TTL = {
      document: 3600,     # dashboard: directory, four days of timetable, the feed
      znamky: 900,        # grades for the current year
      timetable: 3600,    # an explicitly fetched date range
      default: 900
    }.freeze

    attr_reader :root

    def initialize(root: Config.cache_dir, enabled: true)
      @root = root
      @enabled = enabled
    end

    def enabled? = @enabled

    def disable! = (@enabled = false)

    # Reads a cached value or computes and stores it.
    #
    # `immutable: true` marks data from a closed school year, which is kept forever.
    def fetch(*key, kind: :default, immutable: false, &block)
      return block.call unless enabled?

      path = path_for(key)
      ttl = immutable ? FOREVER : TTL.fetch(kind, TTL[:default])

      cached = read(path, ttl)
      return cached if cached

      block.call.tap { |value| write(path, value) }
    end

    def read(path, ttl)
      return nil unless File.exist?(path)
      return nil unless fresh?(path, ttl)

      # Explicit UTF-8, never the locale's default: these payloads are full of Slovak
      # names, and a process launched without LANG (an MCP client, a launchd job) gets
      # US-ASCII as default_external, which makes every read of a cached page fail.
      JSON.parse(File.read(path, encoding: Encoding::UTF_8))
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    def write(path, value)
      FileUtils.mkdir_p(File.dirname(path))
      # Written via a temporary file so a concurrent reader never sees a half-written
      # document; several processes share this directory.
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate(value), mode: "w:UTF-8")
      File.rename(temp, path)
      value
    rescue SystemCallError => e
      Edupage.logger.debug("Could not cache #{path}: #{e.message}")
      value
    end

    def clear
      FileUtils.rm_rf(Dir.glob(File.join(root, "*")))
    end

    def entries = Dir.glob(File.join(root, "**", "*.json"))

    def path_for(key)
      parts = key.flatten.compact.map { |part| sanitize(part) }
      File.join(root, *parts[0..-2], "#{parts.last}.json")
    end

    private

    def fresh?(path, ttl)
      return true if ttl == FOREVER

      Time.now - File.mtime(path) < ttl
    end

    # Ids can be negative and origins are hostnames; keep both filesystem-safe.
    def sanitize(part) = part.to_s.gsub(/[^A-Za-z0-9_.-]/, "_")
  end
end
