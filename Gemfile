source "https://rubygems.org"

gemspec

group :development, :test do
  # Pseudonyms for the people a recorded cassette would otherwise expose.
  gem "faker", "~> 3.5"
  gem "rack-test", "~> 2.2"
  gem "rspec", "~> 3.13"
  # Only `edupage server --public` needs it, so it is not a gemspec dependency: CLI and
  # Homebrew users never compile it. The Docker image installs it itself.
  gem "sqlite3", ">= 2.0"
  gem "vcr", "~> 6.3"
  gem "webmock", "~> 3.25"
end
