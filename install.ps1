# Installs edupage-cli on Windows as a gem. When there is no Ruby at all, Ruby+Devkit
# 3.4 from RubyInstaller comes through winget first, with the MSYS2 toolchain that the
# native gems (puma, nio4r) need to compile.
#
#   irm https://raw.githubusercontent.com/alhafoudh/edupage-cli/main/install.ps1 | iex
#
# iex runs the script inside the user's own session, so it returns instead of calling
# exit, which would close their window. Everything sits in a function called on the
# last line, so a download cut off halfway runs nothing.

function Install-EdupageCli {
  $ErrorActionPreference = 'Stop'
  $rubyInstallerHint = 'Stiahni si Ruby+Devkit 3.4 z https://rubyinstaller.org/downloads/ a spusti tento inštalátor znova.'

  try {
    if (Get-Command ruby -ErrorAction SilentlyContinue) {
      $version = ruby -e 'print RUBY_VERSION'
      # An older Ruby is left alone: a second one installed next to it would lose to it
      # on PATH anyway.
      if ([version]$version -lt [version]'3.2') {
        Write-Host "Našlo sa Ruby $version, ale edupage-cli vyžaduje verziu 3.2 alebo novšiu." -ForegroundColor Red
        Write-Host $rubyInstallerHint -ForegroundColor Red
        return
      }
    } else {
      if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget nie je dostupný. $rubyInstallerHint" -ForegroundColor Red
        return
      }

      Write-Host 'Inštalujem Ruby+Devkit 3.4 cez winget...'
      winget install --id RubyInstallerTeam.RubyWithDevKit.3.4 --exact --silent --accept-package-agreements --accept-source-agreements
      Assert-ExitCode 'winget install'

      # The installer extends PATH in the registry only; this session still has the old one.
      $env:Path = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')
      ) -join ';'
      if (-not (Get-Command ruby -ErrorAction SilentlyContinue)) {
        Write-Host 'Ruby je nainštalované, ale zatiaľ nie je v PATH. Otvor nové okno terminálu a spusti tento inštalátor znova.' -ForegroundColor Yellow
        return
      }

      Write-Host 'Inštalujem nástroje MSYS2 na zostavovanie (ridk install)...'
      ridk install 3
      Assert-ExitCode 'ridk install'
      $version = ruby -e 'print RUBY_VERSION'
    }

    # Nokogiri ships no precompiled gem for Windows arm64 and its bundled libxml2 does not
    # build there, so it is compiled against MSYS2's libxml2 and libxslt first. CI does the same.
    if ((ruby -e 'print RUBY_PLATFORM') -like 'aarch64-*') {
      Write-Host 'Windows na ARM: zostavujem nokogiri s knižnicou libxml2 z MSYS2...'
      ridk exec pacman -S --noconfirm --needed mingw-w64-clang-aarch64-libxml2 mingw-w64-clang-aarch64-libxslt
      Assert-ExitCode 'pacman'
      gem install nokogiri --platform ruby -- --use-system-libraries
      Assert-ExitCode 'gem install nokogiri'
    }

    Write-Host "Inštalujem edupage-cli ako Ruby gem (Ruby $version)..."
    gem install edupage-cli
    Assert-ExitCode 'gem install edupage-cli'

    Write-Host 'Hotovo. Otvor nové okno terminálu a nastav si prihlasovacie údaje:' -ForegroundColor Green
    Write-Host '  setx EDUPAGE_USERNAME "tvoje_pouzivatelske_meno"'
    Write-Host '  setx EDUPAGE_PASSWORD "tvoje_heslo"'
    Write-Host '  setx EDUPAGE_SCHOOL "tvoja_skola"'
    Write-Host 'edupage login na Windows nefunguje, heslo sa načítava z EDUPAGE_PASSWORD.'
  } catch {
    Write-Host "Inštalácia zlyhala: $($_.Exception.Message)" -ForegroundColor Red
  }
}

function Assert-ExitCode([string]$step) {
  if ($LASTEXITCODE -ne 0) { throw "$step skončil s kódom $LASTEXITCODE" }
}

Install-EdupageCli
