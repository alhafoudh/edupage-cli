require "logger"
require "zeitwerk"

require_relative "edupage/version"
# Defines several constants in one file, which does not fit Zeitwerk's file->constant
# mapping; it is also needed everywhere, so it is loaded eagerly and ignored below.
require_relative "edupage/errors"

# Read-only client for Edupage.
#
# Edupage has no public API: every page is server-rendered HTML with JSON embedded in
# <script> blocks. See Edupage::Parsers for how each blob is extracted.
#
# The object graph mirrors how Edupage itself is organised:
#
#   Edupage.account -> School -> Student -> Year -> grades/terms
#
# A session carries two server-side cursors (current child, current school year) which
# Edupage::Session sets transparently; see Session#with_cursor.
module Edupage
  class << self
    # The logged-in account, memoized for the process.
    def account(username: nil, school: nil, cache: nil)
      @account ||= Account.login(username: username, school: school, cache: cache)
    end

    # Drops the memoized account. The persisted session is untouched.
    def reset!
      @account = nil
    end

    def config
      @config ||= Config.load
    end

    attr_writer :config

    def logger
      @logger ||= ::Logger.new($stderr, level: ::Logger::WARN,
                                        formatter: ->(sev, _t, _p, msg) { "[edupage] #{sev.downcase}: #{msg}\n" })
    end

    attr_writer :logger

    def root
      @root ||= File.expand_path("..", __dir__)
    end
  end
end

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect(
  "cli" => "CLI",
  "mcp" => "MCP",
  "asc" => "ASC",
  "api" => "API",
  "env" => "Env"
)
loader.ignore(
  "#{__dir__}/edupage/version.rb",
  "#{__dir__}/edupage/errors.rb",
  "#{__dir__}/edupage/registry/resources.rb"
)
loader.setup
