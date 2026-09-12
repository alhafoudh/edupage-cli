require_relative "lib/edupage/version"

Gem::Specification.new do |spec|
  spec.name    = "edupage-cli"
  spec.version = Edupage::VERSION
  spec.authors = ["Ahmed Al Hafoudh"]
  spec.email   = ["alhafoudh@freevision.sk"]

  spec.summary     = "Read-only prístup k Edupage: Ruby knižnica, CLI, REST API a MCP server"
  spec.description = "ActiveRecord-like prístup k Edupage - školy, žiaci, rozvrhy, domáce " \
                     "úlohy a známky - vystavený zhodne cez Ruby API, CLI, REST API " \
                     "a MCP server. Iba na čítanie."
  spec.license  = "MIT"
  spec.homepage = "https://github.com/alhafoudh/edupage-cli"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "README.md",
    "LICENSE*"
  ]
  spec.bindir      = "exe"
  spec.executables = ["edupage"]
  spec.require_paths = ["lib"]

  spec.add_dependency "mcp", "~> 1.2"
  spec.add_dependency "mechanize", "~> 2.12"
  spec.add_dependency "puma", ">= 6.0"
  spec.add_dependency "sinatra", "~> 4.2"
  spec.add_dependency "thor", "~> 1.3"
  # tty-table pulls tty-screen in itself; it is declared because TTY::Screen is
  # called directly to size the terminal.
  spec.add_dependency "tty-screen", "~> 0.8"
  spec.add_dependency "tty-table", "~> 0.12"
  spec.add_dependency "zeitwerk", "~> 2.6"
end
