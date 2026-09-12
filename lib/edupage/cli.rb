require "io/console"
require "json"
require "shellwords"
require "thor"

module Edupage
  # Command line interface.
  #
  # Resource commands are not written by hand: they are generated from Registry, so the
  # CLI gains a command the moment a resource is declared and its options always match
  # the REST query parameters and the MCP input schema.
  class CLI < Thor
    TYPE_MAP = { integer: :numeric, boolean: :boolean }.freeze

    def self.exit_on_failure? = true

    class_option :username, type: :string, desc: "Edupage login (default: config default_username)"
    class_option :school, type: :string, desc: "School origin (default: config default_school)"
    class_option :student, type: :string, desc: "Student name or id"
    class_option :year, type: :string, desc: "School year, e.g. 2025"
    class_option :no_cache, type: :boolean, desc: "Ignore the cache and refetch"
    class_option :json, type: :boolean, desc: "Output JSON"
    class_option :yaml, type: :boolean, desc: "Output YAML"
    class_option :verbose, type: :boolean, desc: "Log requests to stderr"

    # --- generated resource commands ---------------------------------------------------

    Registry.each do |resource|
      desc resource.name.to_s, resource.summary

      # Scope parameters are class options already; only the resource's own filters
      # become per-command options.
      resource.own_params.each do |param|
        method_option param.name,
                      type: TYPE_MAP.fetch(param.type, :string),
                      desc: param.desc,
                      enum: param.enum? ? param.values : nil,
                      required: param.required
      end

      define_method(resource.name) do
        run_resource(resource)
      end
    end

    # --- credentials -------------------------------------------------------------------

    desc "login", "Verify credentials and store the password in the macOS keychain"
    method_option :username, type: :string, desc: "Edupage login (email)"
    method_option :stdin, type: :boolean, desc: "Read the password from stdin instead of prompting"
    def login
      keychain = require_keychain!
      username = options[:username] || Edupage.config.default_username ||
                 ask("Username (email):")
      school = options[:school] || Edupage.config.default_school || ask("School (e.g. zsdemo):")
      password = options[:stdin] ? $stdin.gets.to_s.chomp : ask_password

      raise Error, "No password given" if password.empty?

      # Verified before it is stored, so a typo never ends up in the keychain.
      users = Client.mauth(school: school, username: username, password: password)
      keychain.store(username: username, password: password)

      say "Stored password for #{username}."
      say "Schools: #{users.map { |u| u[:origin] }.join(", ")}"
      remember_defaults(username, school)
    end

    desc "logout", "Remove the stored password from the keychain"
    method_option :username, type: :string
    def logout
      keychain = require_keychain!
      username = options[:username] || Edupage.config.default_username or
        raise MissingCredentialsError, "No username; pass --username."

      say(keychain.delete(username: username) ? "Removed password for #{username}." : "Nothing stored for #{username}.")
      say "Session cache is separate; use `edupage session logout` to drop it.", :yellow
    end

    desc "auth", "Show where credentials are coming from"
    def auth
      credentials = Credentials.new(username: options[:username], school: options[:school])
      username = safe { credentials.username }

      say Table.plain([
                        auth_row("username", username, credentials.username_source),
                        auth_row("school", safe { credentials.school }, credentials.school_source),
                        auth_row("password", credentials.password_source ? "(set)" : "(missing)",
                                 credentials.password_source),
                        auth_row("keychain", keychain_status(username), nil)
                      ])

      return unless credentials.password_shadowed?

      say "EDUPAGE_PASSWORD is set and overrides the keychain entry.", :yellow
    end

    # --- session and cache ---------------------------------------------------------------

    desc "session SUBCOMMAND", "status | refresh | logout"
    def session(subcommand = "status")
      store = SessionStore.new
      username = Credentials.new(username: options[:username]).username

      case subcommand
      when "status"
        entries = store.all(username)
        return say("No stored sessions for #{username}.") if entries.empty?

        rows = entries.map { |origin, entry| [origin, entry[:userid], "saved #{entry[:saved_at]}"] }
        say Table.plain(rows)
      when "refresh"
        store.delete(username)
        account = Edupage.account(username: username, school: options[:school])
        say "Logged in again: #{account.schools.map(&:origin).join(", ")}"
      when "logout"
        store.delete(username)
        say "Dropped stored sessions for #{username}. The keychain password is untouched."
      else
        raise Error, "Unknown session subcommand #{subcommand.inspect}"
      end
    end

    desc "cache SUBCOMMAND", "info | clear"
    def cache(subcommand = "info")
      store = Cache.new

      case subcommand
      when "info"
        entries = store.entries
        say Table.plain([
                          ["cache dir", ":", store.root],
                          ["entries", ":", entries.size.to_s],
                          ["size", ":", "#{entries.sum { |f| File.size(f) } / 1024} KiB"]
                        ])
      when "clear"
        store.clear
        say "Cache cleared."
      else
        raise Error, "Unknown cache subcommand #{subcommand.inspect}"
      end
    end

    desc "config SUBCOMMAND [KEY] [VALUE]", "path | get | set"
    def config(subcommand = "path", key = nil, value = nil)
      case subcommand
      when "path" then say Edupage.config.path
      when "get" then say(key ? Edupage.config[key].inspect : Edupage.config.to_h.inspect)
      when "set"
        raise Error, "Usage: edupage config set KEY VALUE" if key.nil? || value.nil?

        Edupage.config[key] = value
        Edupage.config.save
        say "#{key} = #{value}"
      else
        raise Error, "Unknown config subcommand #{subcommand.inspect}"
      end
    end

    # --- servers --------------------------------------------------------------------------

    desc "server", "Serve the REST API and the MCP endpoint"
    method_option :host, type: :string, desc: "Bind address (default 127.0.0.1)"
    method_option :port, type: :numeric, desc: "Port (default 4567)"
    method_option :token, type: :string, desc: "Bearer token (default: generated, stored in config)"
    def server
      Server.start(host: options[:host], port: options[:port], token: options[:token],
                   account_options: account_options)
    end

    desc "mcp", "Serve MCP over stdio, for editors and desktop clients"
    def mcp
      Server::MCP.new(account_options: account_options).run_stdio
    end

    MCP_TARGETS = %w[claude-code claude-desktop all].freeze

    CLAUDE_DESKTOP_CONFIG =
      "~/Library/Application Support/Claude/claude_desktop_config.json".freeze

    desc "mcp-add TARGET", "Register this server with #{MCP_TARGETS.join(", ")}"
    method_option :http, type: :boolean,
                         desc: "Register the HTTP endpoint of a running `edupage server` instead of stdio"
    method_option :name, type: :string, desc: "Key under mcpServers (default: edupage)"
    method_option :host, type: :string, desc: "Host for --http"
    method_option :port, type: :numeric, desc: "Port for --http"
    method_option :scope, type: :string, enum: %w[local user project],
                          desc: "Claude Code scope (default: local)"
    method_option :dry_run, type: :boolean, aliases: "-n",
                            desc: "Show what would be done without registering anything"
    map "mcp-add" => :mcp_add
    def mcp_add(target = nil)
      unless MCP_TARGETS.include?(target)
        raise Thor::Error, "Usage: edupage mcp-add TARGET, where TARGET is #{MCP_TARGETS.join(", ")}"
      end

      name = options[:name] || "edupage"
      entry = options[:http] ? http_entry : stdio_entry
      targets = target == "all" ? MCP_TARGETS - ["all"] : [target]

      targets.each do |each|
        case each
        when "claude-code" then add_to_claude_code(name, entry)
        when "claude-desktop" then add_to_claude_desktop(name, entry)
        end
      end
    end

    desc "mcp-config", "Print an mcpServers entry for Claude Desktop or Claude Code"
    method_option :http, type: :boolean,
                         desc: "Connect to a running `edupage server` over HTTP instead of stdio"
    method_option :name, type: :string, desc: "Key under mcpServers (default: edupage)"
    method_option :host, type: :string, desc: "Host for --http"
    method_option :port, type: :numeric, desc: "Port for --http"
    # Thor looks commands up by method name, so the hyphenated form needs mapping.
    map "mcp-config" => :mcp_config
    def mcp_config
      name = options[:name] || "edupage"
      entry = options[:http] ? http_entry : stdio_entry

      # Nothing but the JSON, so `edupage mcp-config > entry.json` and piping into jq
      # both work. Use `mcp-add --dry-run` to see what registering would do.
      $stdout.puts(::JSON.pretty_generate("mcpServers" => { name => entry }))
    end

    desc "version", "Print the version"
    def version = say(VERSION)

    private

    def run_resource(resource)
      Edupage.logger.level = ::Logger::DEBUG if options[:verbose]

      context = Registry::Context.new(
        account: current_account, school: options[:school],
        student: options[:student], year: options[:year]
      )
      result = resource.call(context, options)

      # Only the table view gets the header: --json and --yaml stay byte-identical to
      # what the REST API and the MCP tools return.
      say(chain_header(resource, context)) if table_output? && !resource.scope_chain.empty?
      formatter.render(result, resource: resource)
      say(year_hint(resource, context), :yellow) if empty_year_result?(resource, context, result)
    rescue AmbiguousScopeError => e
      raise Thor::Error, choice_message(e)
    rescue Error => e
      raise Thor::Error, e.message
    end

    # Shows which school, student and year the answer came from, so a list is never
    # ambiguous about whose it is.
    def chain_header(resource, context)
      rows = resource.scope_chain.map do |level|
        case level
        when :school then ["school", ":", "#{context.school.origin}  (#{context.school.name})"]
        when :student then ["student", ":", context.student.to_s]
        when :year then ["year", ":", "#{context.year}#{context.year_defaulted? ? "  [default]" : ""}"]
        end
      end

      "#{Table.plain(rows)}\n"
    end

    def choice_message(error)
      rows = error.candidates.map { |c| ["--#{error.level}", c[:id].to_s, c[:label].to_s] }

      "No #{error.level} selected. Pick one:\n#{Table.plain(rows, indent: 2)}"
    end

    # In September the current year is empty and last year's data is what was meant, so
    # an empty defaulted year points at the years that do have something.
    def year_hint(_resource, context)
      elsewhere = context.student.years.reject(&:current?).select { |y| y.grade_count.positive? }
      return "Nothing here for #{context.year}." if elsewhere.empty?

      suggestions = elsewhere.first(3).map { |y| "--year #{y.id} (#{y.grade_count})" }
      "Nothing here for #{context.year}. Try #{suggestions.join(", ")}."
    end

    def empty_year_result?(resource, context, result)
      table_output? && resource.scope == :year && context.year_defaulted? &&
        result.respond_to?(:empty?) && result.empty?
    end

    def table_output? = !options[:json] && !options[:yaml]

    # Not named `account`: that is a generated command, and a private method of the
    # same name would silently replace it.
    def current_account
      @current_account ||= Edupage.account(
        username: options[:username], school: options[:school],
        cache: Cache.new(enabled: !options[:no_cache])
      )
    end

    # Defaults the long-running servers inherit from the command line, so
    # `edupage server --username x --school y` needs no config file.
    def account_options
      {
        username: options[:username],
        school: options[:school],
        student: options[:student],
        year: options[:year]
      }.compact
    end

    def formatter
      Formatter.new(output: $stdout,
                    format: options[:json] ? :json : (options[:yaml] ? :yaml : :table))
    end

    def require_keychain!
      unless Credentials::Keychain.available?
        raise Thor::Error, "The macOS keychain is unavailable on #{RUBY_PLATFORM}; use EDUPAGE_PASSWORD."
      end

      Credentials::Keychain.new
    end

    def ask_password
      $stderr.print "Password: "
      password = $stdin.noecho(&:gets).to_s.chomp
      $stderr.puts
      password
    end

    def remember_defaults(username, school)
      changed = false
      if Edupage.config.default_username.nil?
        Edupage.config["default_username"] = username
        changed = true
      end
      if Edupage.config.default_school.nil?
        Edupage.config["default_school"] = school
        changed = true
      end
      return unless changed

      Edupage.config.save
      say "Saved defaults to #{Edupage.config.path}."
    end

    # --- mcp-config helpers -------------------------------------------------------------

    # stdio needs no token: the client owns the process, so there is nothing to
    # authenticate. It is the better default for a local tool.
    def stdio_entry
      entry = { "command" => executable_path, "args" => ["mcp"] }

      if bundler_gemfile
        # Running from a checkout rather than an installed gem. Going through bundler
        # with an absolute BUNDLE_GEMFILE is what makes this work from any directory -
        # MCP clients start servers with a working directory of their own choosing.
        entry["command"] = bundler_path
        entry["args"] = ["exec", executable_path, "mcp"]
        entry["env"] = { "BUNDLE_GEMFILE" => bundler_gemfile }
      end

      # The account is authentication, not a level of the chain, so pinning it is safe;
      # school and student stay out on purpose, so the model has to choose them.
      username = safe { Credentials.new(username: options[:username]).username }
      entry["args"] += ["--username", username] if username
      entry
    end

    def http_entry
      host = options[:host] || Edupage.config.server["host"] || Server::DEFAULT_HOST
      port = options[:port] || Edupage.config.server["port"] || Server::DEFAULT_PORT

      {
        "type" => "http",
        "url" => "http://#{host}:#{port}/mcp",
        "headers" => { "Authorization" => "Bearer #{Edupage.config.server_token}" }
      }
    end

    def executable_path
      File.expand_path($PROGRAM_NAME)
    end

    def bundler_gemfile
      gemfile = ENV["BUNDLE_GEMFILE"]
      return File.expand_path(gemfile) if gemfile && File.exist?(gemfile)

      nil
    end

    def bundler_path
      path = `which bundle 2>/dev/null`.strip
      path.empty? ? "bundle" : path
    end

    # Claude Code owns its own config, so registration goes through its CLI rather than
    # editing the file behind its back.
    def add_to_claude_code(name, entry)
      command = claude_add_command(name, entry)

      if options[:dry_run]
        say "claude-code   : would run"
        say "  #{command}"
        return
      end

      raise Thor::Error, "`claude` is not on PATH; install Claude Code or use mcp-config" if which("claude").nil?

      # Idempotent: `claude mcp add` refuses a name it already knows, so an existing
      # entry is dropped first and re-added. Running this twice converges instead of
      # failing the second time.
      existed = claude_code_knows?(name)
      system("claude", "mcp", "remove", name, *scope_arguments, out: File::NULL, err: File::NULL) if existed

      raise Thor::Error, "`claude mcp add` failed" unless system(command, out: File::NULL)

      say "claude-code   : #{existed ? "updated" : "added"} #{name}#{scope_note}"
    end

    def claude_code_knows?(name)
      system("claude", "mcp", "get", name, out: File::NULL, err: File::NULL)
    end

    def scope_arguments = options[:scope] ? ["-s", options[:scope]] : []
    def scope_note = options[:scope] ? " (#{options[:scope]} scope)" : ""

    # Claude Desktop has no CLI, so its JSON is merged by hand - preserving the other
    # servers and the unrelated top-level keys it keeps in the same file.
    def add_to_claude_desktop(name, entry)
      path = File.expand_path(CLAUDE_DESKTOP_CONFIG)
      config = read_json_file(path)
      servers = config["mcpServers"] ||= {}

      # Idempotent: an identical entry is left alone, a different one is brought into
      # line, and a missing one is added.
      current = servers[name]
      action = if current.nil? then :added
               elsif current == entry then :unchanged
               else :updated
               end

      if options[:dry_run]
        say "claude-desktop: would leave #{name.inspect} unchanged in #{path}" and return if action == :unchanged

        say "claude-desktop: would #{action == :added ? "add" : "update"} #{name.inspect} in #{path}"
        say ::JSON.pretty_generate(name => entry).gsub(/^/, "  ")
        return
      end

      return say "claude-desktop: #{name} already up to date" if action == :unchanged

      servers[name] = entry
      write_json_file(path, config)
      say "claude-desktop: #{action} #{name} in #{path}"
      say "                restart Claude Desktop for it to pick this up", :yellow
    end

    def read_json_file(path)
      return {} unless File.exist?(path)

      # UTF-8 explicitly; other servers in this file may have non-ASCII values and the
      # locale is not guaranteed to be set.
      content = File.read(path, encoding: Encoding::UTF_8)
      return {} if content.strip.empty?

      ::JSON.parse(content)
    rescue ::JSON::ParserError => e
      raise Thor::Error, "#{path} is not valid JSON (#{e.message}); fix or move it first"
    end

    # Writes via a temporary file and keeps one backup: this is a config the user owns
    # and may have other servers in.
    def write_json_file(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.cp(path, "#{path}.bak") if File.exist?(path)

      temp = "#{path}.#{Process.pid}.tmp"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.set_encoding(Encoding::UTF_8)
        file.write(::JSON.pretty_generate(data))
        file.write("\n")
      end
      File.rename(temp, path)
    end

    def which(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
         .map { |dir| File.join(dir, command) }
         .find { |candidate| File.executable?(candidate) && !File.directory?(candidate) }
    end

    # Builds the equivalent `claude mcp add` invocation, shell-quoted so it can be
    # pasted or piped straight into a shell.
    #
    # The two transports take different shapes: stdio passes the subprocess after `--`,
    # while HTTP takes a URL and repeatable --header flags.
    def claude_add_command(name, entry)
      parts = ["claude", "mcp", "add"]
      parts += ["-s", options[:scope]] if options[:scope]

      if entry["type"] == "http"
        parts += ["--transport", "http", name, entry["url"]]
        entry.fetch("headers", {}).each { |key, value| parts += ["--header", "#{key}: #{value}"] }
      else
        # The name has to come before -e: `claude mcp add` takes --env variadically, so
        # a name placed after it is swallowed as another KEY=value and rejected with
        # "Invalid environment variable format".
        parts << name
        entry.fetch("env", {}).each { |key, value| parts += ["-e", "#{key}=#{value}"] }
        parts += ["--", entry["command"], *entry["args"]]
      end

      parts.map { |part| shell_quote(part) }.join(" ")
    end

    # Shellwords.escape is correct but backslash-escapes every `=` and space, which
    # makes the line hard to read. Only what actually needs quoting gets quoted.
    SHELL_SAFE = %r{\A[A-Za-z0-9_@%+=:,./-]+\z}

    def shell_quote(part)
      return part if part.match?(SHELL_SAFE)

      "'#{part.gsub("'", %q('\''))}'"
    end

    def keychain_status(username)
      return "unavailable on #{RUBY_PLATFORM}" unless Credentials::Keychain.available?
      return "available (service edupage-cli), but no username to look up" unless username

      Credentials::Keychain.new.stored?(username: username) ? "stored for #{username}" : "nothing stored for #{username}"
    end

    def auth_row(label, value, source)
      [label, ":", value || "(missing)", source ? "[#{source}]" : ""]
    end

    def safe
      yield
    rescue Error
      nil
    end
  end
end
