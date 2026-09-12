# edupage-cli

Read-only access to an [Edupage](https://www.edupage.org) school account, as a Ruby
library, a CLI, a REST API and an MCP server - all four backed by the same code and
kept in step by a parity test.

Edupage has no public API. Every page is server-rendered HTML with JSON embedded in
`<script>` blocks, and the session carries hidden cursors for "current child" and
"current school year" that have to be steered before a fetch means anything. This
handles all of that.

## Install

```bash
bundle install
bundle exec exe/edupage login
```

`login` verifies the password against Edupage before storing it in the macOS keychain,
so a typo never gets saved.

## Credentials

Resolved in this order:

| Order | Source |
|---|---|
| 1 | `EDUPAGE_USERNAME`, `EDUPAGE_PASSWORD`, `EDUPAGE_SCHOOL` |
| 2 | macOS keychain (service `edupage-cli`), via `edupage login` |

`edupage auth` shows which one is in play, and warns when `EDUPAGE_PASSWORD` is
shadowing a stored password - otherwise `edupage login` looks like it did nothing.

Non-secret defaults live in `~/.config/edupage-cli/config.yml`; sessions and cached
pages in `~/.cache/edupage-cli/`.

## The chain

Everything hangs off `account > school > student > year`, and no level can be skipped.
Each one resolves the same way: an explicit choice wins, a single option is taken
silently, and anything else is refused with the options listed.

```
$ edupage students
No school selected. Pick one:
  --school zsdemo   Základná škola Demo
  --school zusdemo  Základná umelecká škola Demo
```

A config default is **not** a choice: `default_school` only says which
`*.edupage.org` host to log in against, never whose data you are reading.

The year is the one exception - it defaults to the current one, since "now" is
unambiguous. The output says which year it used, and points elsewhere when that year
is empty:

```
$ edupage grades --school zsdemo --student Jana
school  : zsdemo  (Základná škola Demo)
student : Jana Nováková (4.A)
year    : 2026/2027 (current)  [default]
No records.
Nothing here for 2026/2027 (current). Try --year 2025 (172), --year 2024 (116).
```

## CLI

```bash
edupage schools
edupage students   --school zsdemo
edupage timetable  --school zsdemo --student Jana --from 2026-09-21 --to 2026-09-25
edupage homeworks  --school zsdemo --student Jana --due 2026-09-14
edupage years      --school zsdemo --student Jana
edupage grades     --school zsdemo --student Jana --year 2025 --term P1 --subject MAT
edupage timeline   --school zsdemo --student Peter --type message
```

Global options: `--school --student --year --username --json --yaml --no-cache --verbose`.
Student names match on a unique prefix, so `--student Jana` is enough.

Table output carries a header naming the school, student and year it came from; `--json`
and `--yaml` do not, so they stay byte-identical to the REST and MCP payloads.

Housekeeping: `edupage auth`, `edupage session status|refresh|logout`,
`edupage cache info|clear`, `edupage config path|get|set`.

## Library

```ruby
require "edupage"

school = Edupage.account.school("zsdemo")
jana = school.students.find_by(name: /Jana/)

jana.timetable                                  # today
jana.timetable(Date.today..Date.today + 6)      # a week
jana.homeworks.where(subject: "SJL").order(:due_on)

jana.years                                      # 2026 (current), 2025, 2024 ...
jana.year(2025).grades.where(term: :P1, subject: "MAT")
jana.grades                                     # shorthand for the current year
```

Collections are lazy and chainable: `where order limit offset find_by first count`.
`where(name: ...)` searches a record's name, short code and id; every other key
compares that attribute, and accepts a value, a regexp, a range, an array or a lambda.

## Server

```bash
edupage server            # REST on /api/v1, MCP on /mcp
edupage mcp               # MCP over stdio, for editors and desktop clients
```

Binds to `127.0.0.1` with a bearer token generated into the config file on first run.
Every route is `GET`; the MCP tools are all annotated read-only.

### Wiring MCP up

`edupage mcp-config` prints the `mcpServers` entry; `--command` prints the equivalent
`claude mcp add` line instead. Both transports are available:

```bash
edupage mcp-config                       # stdio JSON, for Claude Desktop or .mcp.json
edupage mcp-config --command             # claude mcp add ... (stdio)
edupage mcp-config --http                # streamable HTTP JSON, with the bearer token
edupage mcp-config --http --command      # claude mcp add --transport http ...
```

stdio is the better default for a local tool: the client owns the process, so there is
nothing to authenticate and no server to keep running. The HTTP variant points at
`/mcp` on a running `edupage server` and carries the token as an `Authorization`
header - useful when several clients share one process.

The JSON goes to stdout and the notes to stderr, so
`edupage mcp-config > entry.json` gives a clean file. Neither variant pins a school or
student: those are levels of the chain and the model has to choose them per call.

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:4567/api/v1/schools/zsdemo/students/Jana/years/2025/grades?term=P1"
```

## How the surfaces stay in step

Resources are declared once, in `lib/edupage/registry/resources.rb`:

```ruby
resource :grades do
  scope   :year
  summary "Grades for a school year"
  param   :term, type: :enum, values: %w[P1 P2], desc: "Half-year"
  resolve ->(year, p) { year.grades.where(term: p[:term]) }
end
```

The CLI command, the REST route and the MCP tool are all generated from that, and
`spec/registry_parity_spec.rb` fails if any of them goes missing or its parameters
drift. The `--json` output, the REST body and the MCP tool result run through one
serializer, so they are byte-identical.

`scope` also declares which levels of the chain a resource stands on, so all three
surfaces enforce it the same way: the REST path carries them as segments, the MCP input
schema marks them required, and the CLI refuses with a list of options.

## Notes on Edupage itself

Things worth knowing, all verified against a live account:

- **One login can span several schools.** `mauth` returns one session per school.
- **The session holds a current child and a current school year.** Switching either is
  a side effect on shared server state, so it happens under a file lock and every
  response is checked against what was asked for.
- **Those switches lag.** Edupage acknowledges a switch immediately but serves the
  previous child's or year's page for another request or two, so fetches retry until
  the page agrees. Returning the lagging page would quietly hand back the wrong
  child's timetable.
- **The directory changes between years.** The 2025 class list is not the 2026 one, so
  the year is part of every cache key.
- **The timeline is shared across a parent's children** and split locally by the
  `childGroups` map.
- **Homework comes in two shapes** - set to a class, or to one pupil. Both are needed:
  on the account this was built against, 15 of one child's 16 tasks are the second kind.

## Development

```bash
bundle exec rspec
```

Specs run against handcrafted payloads rather than recorded pages: the real ones are
hundreds of kilobytes and carry other people's children's names.

## Scope

Read-only, deliberately. Nothing here writes to Edupage - no replies, no marking things
done, no signing grades. `spec/registry_parity_spec.rb` asserts that no write endpoint
is referenced anywhere in `lib/`.
