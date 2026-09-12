require "fileutils"
require "securerandom"
require "yaml"

module Edupage
  # User configuration in ~/.config/edupage-cli/config.yml.
  #
  # Holds only non-secret settings. The password never lives here - see Credentials.
  class Config
    DEFAULTS = {
      # Which *.edupage.org host to authenticate against. It is a login anchor only:
      # it does not choose which school's data is read - see Registry::Context.
      "default_school" => nil,
      "default_username" => nil,
      "server" => {
        "host" => "127.0.0.1",
        "port" => 4567,
        "token" => nil
      }
    }.freeze

    class << self
      def load(path = self.path)
        # Read as UTF-8 rather than through the locale, so a process started without
        # LANG (an MCP client, launchd) does not choke on a non-ASCII value.
        raw = File.exist?(path) ? (YAML.safe_load(File.read(path, encoding: Encoding::UTF_8)) || {}) : {}
        new(deep_merge(DEFAULTS, raw), path: path)
      end

      def path
        ENV["EDUPAGE_CONFIG"] || File.join(config_home, "edupage-cli", "config.yml")
      end

      def config_home
        ENV["XDG_CONFIG_HOME"] || File.expand_path("~/.config")
      end

      def cache_home
        ENV["XDG_CACHE_HOME"] || File.expand_path("~/.cache")
      end

      def cache_dir
        ENV["EDUPAGE_CACHE_DIR"] || File.join(cache_home, "edupage-cli")
      end

      def deep_merge(base, other)
        base.merge(other) do |_key, a, b|
          a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : (b.nil? ? a : b)
        end
      end
    end

    attr_reader :path

    def initialize(data, path: self.class.path)
      @data = data
      @path = path
    end

    def [](key)
      @data[key.to_s]
    end

    def []=(key, value)
      @data[key.to_s] = value
    end

    def default_school = self["default_school"]
    def default_username = self["default_username"]

    def server = self["server"] || {}

    # Lazily minted on first use so `edupage server` works without setup, but the token
    # is only generated once and then persisted.
    def server_token
      server["token"] || begin
        token = SecureRandom.urlsafe_base64(32)
        @data["server"] = server.merge("token" => token)
        save
        token
      end
    end

    def to_h = @data

    def save
      FileUtils.mkdir_p(File.dirname(path))
      # Written 0600: the file carries the server bearer token.
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.set_encoding(Encoding::UTF_8)
        f.write(YAML.dump(@data))
      end
      self
    end
  end
end
