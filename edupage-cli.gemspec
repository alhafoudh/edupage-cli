require_relative "lib/edupage/version"

Gem::Specification.new do |spec|
  spec.name    = "edupage-cli"
  spec.version = Edupage::VERSION
  spec.authors = ["Ahmed Al Hafoudh"]
  spec.email   = ["alhafoudh@freevision.sk"]

  spec.summary     = "Read-only Ruby library, CLI, REST and MCP server for Edupage"
  spec.description = "ActiveRecord-like access to Edupage (schools, students, timetables, " \
                     "homeworks, grades) exposed identically through a Ruby API, a CLI, " \
                     "a REST API and an MCP server."
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
  spec.add_dependency "zeitwerk", "~> 2.6"
end
