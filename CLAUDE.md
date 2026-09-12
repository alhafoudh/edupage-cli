# edupage-cli

Ruby CLI and ActiveRecord-like library on top of the unofficial Edupage API (scraping
the session-based site). Read-only.

Obsidian tracking: no

## Environment

Credentials live in `mise.toml` (`EDUPAGE_SCHOOL`, `EDUPAGE_USERNAME`,
`EDUPAGE_PASSWORD`, pulled from 1Password). Run commands through `mise exec -- ...`,
otherwise the environment is missing.

## Hard rules

- Read-only operations against Edupage only. Never write anything to the production
  account (no createItem, createReply, homeworkFlag, signing grades).
- Tests run on rspec + VCR. Cassettes must have `PHPSESSID`/`esid`, the password and
  the username filtered out.

## Language

- Write this file, commit messages, code, comments and identifiers in English.
- The README is in Slovak on purpose; leave it that way.
