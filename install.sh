#!/bin/sh
# Installs edupage-cli on macOS (and Linux): through Homebrew when it is there,
# otherwise as a gem into an existing Ruby 3.2+. It never installs Homebrew or Ruby.
#
#   curl -fsSL https://raw.githubusercontent.com/alhafoudh/edupage-cli/main/install.sh | sh
#
# Everything runs from main, called on the last line, so a download cut off halfway
# never executes a partial script.
set -eu

say() {
  printf '%s\n' "$*"
}

fail() {
  printf '%s\n' "$*" >&2
}

main() {
  if command -v brew >/dev/null 2>&1; then
    say "Inštalujem edupage-cli cez Homebrew..."
    brew install alhafoudh/edupage/edupage-cli
    say "Hotovo. Prihlás sa príkazom: edupage login"
    return
  fi

  if command -v ruby >/dev/null 2>&1 && command -v gem >/dev/null 2>&1; then
    version=$(ruby -e 'print RUBY_VERSION')
    if ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2"))'; then
      say "Inštalujem edupage-cli ako Ruby gem (Ruby $version)..."
      install_gem
      say "Hotovo. Prihlás sa príkazom: edupage login"
      return
    fi
    fail "Našlo sa Ruby $version, ale edupage-cli vyžaduje verziu 3.2 alebo novšiu."
  fi

  fail "edupage-cli vyžaduje Homebrew alebo Ruby 3.2 alebo novšie."
  fail "Nainštaluj si Homebrew z https://brew.sh a spusti tento inštalátor znova,"
  fail "alebo si nainštaluj Ruby 3.2+ (napríklad cez mise alebo rbenv)."
  exit 1
}

install_gem() {
  # A Ruby from mise, rbenv or asdf owns its gem directory. A system Ruby does not, so
  # the gem goes into the user's home, whose bin directory is often missing from PATH.
  if ruby -e 'exit(File.writable?(Gem.dir))'; then
    gem install edupage-cli
    bindir=$(ruby -e 'print Gem.bindir')
  else
    gem install --user-install edupage-cli
    bindir="$(ruby -e 'print Gem.user_dir')/bin"
  fi

  if ! command -v edupage >/dev/null 2>&1; then
    say "Príkaz edupage zatiaľ nie je v PATH. Pridaj tento riadok do profilu svojho shellu:"
    say "  export PATH=\"$bindir:\$PATH\""
  fi
}

main "$@"
