# Public MCP Server with Edupage OAuth Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `edupage server --public` serves the existing MCP tools to any OAuth client (Claude connectors first) behind a built-in OAuth 2.1 server whose login form takes Edupage credentials, including interactive two-factor approval, with strict per-account isolation.

**Architecture:** A new `Edupage::Server::Public` namespace adds a Sinatra app with OAuth endpoints, an SQLite store of grants whose Edupage credentials are encrypted under keys derived from the OAuth tokens, and a per-grant runtime (own `Account`, in-memory session store, own cache, own mutex). `/mcp` authenticates the bearer token, unlocks the grant and builds a per-request `MCP::Server` whose `server_context` carries that grant's runtime. The existing non-public server is untouched.

**Tech Stack:** Ruby 3.2+, Sinatra 4, Puma, mcp 1.5.x (Streamable HTTP, stateless), Mechanize, OpenSSL (HKDF, AES-256-GCM), sqlite3 (soft dependency), rspec + rack-test + WebMock/VCR, Docker multi-stage, GitHub Actions + GHCR.

**Spec:** `docs/superpowers/specs/2026-11-25-public-mcp-oauth-design.md`

## Global Constraints

- Read-only against Edupage. Never call createItem, createReply, homeworkFlag or grade signing. Login, 2FA confirmation and session pings are the only non-GET calls allowed besides existing read endpoints.
- Code, comments, identifiers, commit messages in English. README stays Slovak. Login and 2FA pages are Slovak.
- No commits during execution. The owner asks for one single commit at the end.
- Run everything through `mise exec -- bundle exec ...`.
- Without `--public` the server behaves exactly as today; all existing specs pass unchanged.
- `sqlite3` is not a gemspec dependency. It goes into the Gemfile `:development, :test` group and the Docker image. `--public` without it fails at startup with: `edupage server --public needs the sqlite3 gem (gem install sqlite3)`.
- Required env in public mode: `EDUPAGE_PUBLIC_URL` (https base URL, or `--public-url`), `EDUPAGE_SECRET_KEY` (at least 32 bytes after base64 or hex decoding). Optional: `EDUPAGE_DATA_DIR` (image default `/data`), `EDUPAGE_TRUST_PROXY` (`1` enables `X-Forwarded-For`).
- Lifetimes: authorization code 60 s single use; access token 3600 s; refresh token 90 days, renewed on every refresh; grants unused for 90 days deleted; pending authorization 10 min; 2FA wait 5 min; idle runtime eviction 30 min.
- Login rate limit: 5 failures per 15 minutes per client IP and per `username|school`.
- PKCE `S256` only. Public clients only (`token_endpoint_auth_method: none`).
- Never log request bodies, `/oauth/*` query strings, `Authorization` headers, tokens, passwords, 2FA codes or Edupage session ids. `inspect` of every object holding them must redact.
- Cassettes and fixtures: `PHPSESSID`/`esid`, password, username, 2FA codes, `sgn`, `edid` and tokens filtered.

## Review Focus

1. Claude fires parallel tool calls on one grant: calls are serialized per grant, so one call never sees another's child/year cursor. Test in Task 9.
2. Server restarts: in-memory Edupage sessions are gone; the next call logs in again through `mauth`; a 2FA school answers with a "reconnect the connector" tool error, never a 500. Test in Task 9.
3. Access token expires mid-conversation: `/mcp` answers 401 with `WWW-Authenticate` (`resource_metadata`), not a tool error, so the client refreshes. Test in Task 9.
4. Password changed on Edupage: the re-login error deletes the grant and `/mcp` answers 401. Test in Task 9.
5. User presses Back or submits the login form twice after the code was issued: friendly "this login request already finished, start again from Claude" page, no crash, no second grant. Test in Task 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/edupage/static_credentials.rb` | Credentials object built from given values (no env, no keychain) |
| `lib/edupage/memory_session_store.rb` | `SessionStore` interface kept in memory, reentrant lock |
| `lib/edupage/web_login.rb` | Edupage web login + two-factor protocol client |
| `lib/edupage/server/public.rb` | Namespace, `Public.start` |
| `lib/edupage/server/public/settings.rb` | Env/option parsing and validation |
| `lib/edupage/server/public/crypto.rb` | Token generation, hashing, HKDF, AES-GCM seal/open |
| `lib/edupage/server/public/store.rb` | SQLite schema and queries |
| `lib/edupage/server/public/grants.rb` | Grant lifecycle: code, exchange, refresh, revoke, unlock, cleanup |
| `lib/edupage/server/public/clients.rb` | DCR, Client ID Metadata Documents, redirect URI rules |
| `lib/edupage/server/public/rate_limiter.rb` | In-memory failure counters |
| `lib/edupage/server/public/pending.rb` | In-memory pending authorizations (login form state, 2FA) |
| `lib/edupage/server/public/login_flow.rb` | Password step + 2FA steps, produces the grant |
| `lib/edupage/server/public/runtimes.rb` | Per-grant `Account`, mutex, eviction |
| `lib/edupage/server/public/app.rb` | Sinatra: well-known, OAuth endpoints, login pages, `/mcp`, `/healthz` |
| `lib/edupage/server/public/views/*.erb` | `layout`, `login`, `two_factor`, `notice` |
| `lib/edupage/server/public/request_log.rb` | Rack middleware, redacted access log |
| `lib/edupage/server/mcp.rb` (modify) | Public tool variant, `respond` takes an account |
| `lib/edupage/server.rb`, `lib/edupage/cli.rb` (modify) | `--public`, `--public-url` |
| `Dockerfile`, `.dockerignore` | Image |
| `.github/workflows/release.yml`, `ci.yml` (modify) | Publish and smoke-build image |
| `README.md` (modify) | Slovak hosting section |

Zeitwerk: `lib/edupage/server/public/views` must be ignored by the loader (`loader.ignore`), check `lib/edupage.rb`.

---

### Task 1: Static credentials and in-memory session store

**Files:**
- Create: `lib/edupage/static_credentials.rb`, `lib/edupage/memory_session_store.rb`
- Test: `spec/static_credentials_spec.rb`, `spec/memory_session_store_spec.rb`

**Interfaces:**
- Produces: `Edupage::StaticCredentials.new(username:, password:, school:)` with `#username`, `#password`, `#school`, `#to_h` (no password), `#inspect` (no password). Duck-types `Credentials` as used by `Account` and `Session`.
- Produces: `Edupage::MemorySessionStore.new` with the exact public API of `SessionStore`: `fetch(username, origin)`, `all(username)`, `store(username, origin, session_id:, userid:, role:, name:)`, `delete(username, origin = nil)`, `clear`, `with_lock { }` (reentrant `Monitor`), plus `#inspect` that hides session ids.

- [ ] **Step 1: Write failing specs**

```ruby
RSpec.describe Edupage::StaticCredentials do
  subject(:creds) { described_class.new(username: "p@example.com", password: "s3cret", school: "zsdemo") }

  it("exposes the values") { expect([creds.username, creds.password, creds.school]).to eq(["p@example.com", "s3cret", "zsdemo"]) }
  it("never shows the password") { expect([creds.inspect, creds.to_s, creds.to_h.to_s].join).not_to include("s3cret") }
end

RSpec.describe Edupage::MemorySessionStore do
  subject(:store) { described_class.new }

  it "round-trips like SessionStore" do
    store.store("u", "zsdemo", session_id: "abc", userid: "Rodic-1", role: "Rodic", name: "A")
    expect(store.fetch("u", "zsdemo")).to include(session_id: "abc", role: "Rodic")
    expect(store.all("u").keys).to eq(["zsdemo"])
  end

  it "deletes one origin or the whole user" do
    store.store("u", "a", session_id: "1"); store.store("u", "b", session_id: "2")
    store.delete("u", "a"); expect(store.all("u").keys).to eq(["b"])
    store.delete("u"); expect(store.all("u")).to eq({})
  end

  it "has a reentrant lock" do
    expect { store.with_lock { store.with_lock { :ok } } }.not_to raise_error
  end

  it("never writes to disk") { store.store("u", "a", session_id: "1"); expect(Dir.glob(File.join(Edupage::Config.cache_dir, "**", "*"))).to be_empty }
  it("hides session ids in inspect") { store.store("u", "a", session_id: "secretsid"); expect(store.inspect).not_to include("secretsid") }
end
```

- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/static_credentials_spec.rb spec/memory_session_store_spec.rb` - expected FAIL (uninitialized constant).
- [ ] **Step 3: Implement both classes.** Store returns hashes with the same symbol keys as `SessionStore#symbolize`.
- [ ] **Step 4: Run the same command** - expected PASS. Also add a spec that `Edupage::Account.login(credentials: StaticCredentials, store: MemorySessionStore, cache: Cache.new(enabled: false))` with a stubbed `Client.mauth` stores sessions in the memory store and never calls `Edupage::Credentials.new`.

### Task 2: Crypto

**Files:**
- Create: `lib/edupage/server/public/crypto.rb`
- Test: `spec/server/public/crypto_spec.rb`

**Interfaces:**
- Produces module `Edupage::Server::Public::Crypto`:
  - `generate_token(prefix) -> [id, secret, string]`; `string == "#{prefix}_#{id}.#{secret}"`; id 16 random bytes hex, secret 32 random bytes base64url without padding. Prefixes: `ec` code, `ea` access, `er` refresh.
  - `parse_token(string) -> [prefix, id, secret]` or `nil` for malformed input.
  - `digest(secret) -> String` (hex SHA-256).
  - `secure_equal?(a, b) -> Boolean` (`OpenSSL.fixed_length_secure_compare` after length check).
  - `random_key -> String` (32 bytes).
  - `derive_key(pepper:, secret:) -> String` = `OpenSSL::KDF.hkdf(secret, salt: pepper, info: "edupage-public-wrap-v1", length: 32, hash: "SHA256")`.
  - `seal(key, plaintext, aad:) -> String` = base64(`iv(12) + tag(16) + ciphertext`), AES-256-GCM.
  - `open(key, sealed, aad:) -> String`, raises `Crypto::DecryptError` on any failure.

- [ ] **Step 1: Failing specs:** `seal`/`open` round-trip; `open` with wrong key raises `DecryptError`; wrong `aad` raises `DecryptError`; tampered byte raises `DecryptError`; `derive_key` is deterministic for same inputs and differs for different pepper; `parse_token("ea_x")` is nil; `parse_token(generate_token("ea").last)` returns the same id and secret.
- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/server/public/crypto_spec.rb` - FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** - PASS.

### Task 3: Settings and SQLite store

**Files:**
- Create: `lib/edupage/server/public/settings.rb`, `lib/edupage/server/public/store.rb`
- Modify: `Gemfile` (add `gem "sqlite3", ">= 2.0"` to `:development, :test`)
- Test: `spec/server/public/settings_spec.rb`, `spec/server/public/store_spec.rb`

**Interfaces:**
- Produces `Settings.from_env(env = ENV, public_url: nil) -> Settings` with readers `public_url` (no trailing slash), `issuer` (= public_url), `resource` (= `"#{public_url}/mcp"`), `host` (URI host of public_url), `pepper` (decoded bytes), `data_dir`, `trust_proxy?`. Raises `Edupage::Error` with a message naming the variable when `EDUPAGE_PUBLIC_URL` is missing or not `https://` (allow `http://localhost` and `http://127.0.0.1` for local testing), or when `EDUPAGE_SECRET_KEY` decodes to fewer than 32 bytes. Base64 tried first, then hex, then raw bytes.
- Produces `Store.new(path)`; creates `0600` file, `PRAGMA journal_mode=WAL`, `busy_timeout 5000`, schema:

```sql
CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, metadata TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS grants (id TEXT PRIMARY KEY, client_id TEXT NOT NULL, sealed_credentials TEXT NOT NULL,
  created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS tokens (id TEXT PRIMARY KEY, grant_id TEXT NOT NULL REFERENCES grants(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, secret_hash TEXT NOT NULL, wrapped_key TEXT NOT NULL, expires_at INTEGER NOT NULL,
  used_at INTEGER, extra TEXT);
CREATE INDEX IF NOT EXISTS tokens_grant ON tokens(grant_id);
```
  `PRAGMA foreign_keys=ON`. Methods (all take/return plain hashes with symbol keys, times as Integer epoch): `insert_client(id, metadata)`, `find_client(id)`, `insert_grant(row)`, `find_grant(id)`, `touch_grant(id, at)`, `delete_grant(id)`, `insert_token(row)`, `find_token(id)`, `mark_token_used(id, at)`, `delete_tokens(grant_id, kind:)`, `expired_grant_ids(before)`, `delete_expired_tokens(now)`, `transaction { }`.
- Produces `Public.require_sqlite!` in `store.rb`: `require "sqlite3"` rescuing `LoadError` into `Edupage::Error` with the exact Global Constraints message.

- [ ] **Step 1: Failing specs:** settings errors for each missing/invalid variable (message contains the variable name); `resource` equals `https://mcp.example.com/mcp` for `EDUPAGE_PUBLIC_URL=https://mcp.example.com/`; store round-trips each table; deleting a grant cascades its tokens; file mode is `0600` (`posix: true`).
- [ ] **Step 2: Run** `mise exec -- bundle install && mise exec -- bundle exec rspec spec/server/public/settings_spec.rb spec/server/public/store_spec.rb` - FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** - PASS.

### Task 4: Grants

**Files:**
- Create: `lib/edupage/server/public/grants.rb`
- Test: `spec/server/public/grants_spec.rb`

**Interfaces:**
- Consumes: `Crypto`, `Store`, `Settings#pepper`.
- Produces `Grants.new(store:, pepper:, clock: -> { Time.now.to_i })`:
  - `issue_code(client_id:, credentials:, redirect_uri:, code_challenge:, resource:) -> [grant_id, code_string]`. `credentials` is a Hash `{username:, password:, school:, schools: [origins], two_factor_origins: [origins]}`; sealed as JSON under a random data key, `aad: grant_id`; data key wrapped under `derive_key(pepper:, secret: code_secret)`; code row `extra` holds `redirect_uri`, `code_challenge`, `resource`, `client_id`.
  - `exchange_code(code_string, client_id:, redirect_uri:, code_verifier:) -> Tokens` (Struct `grant_id, access_token, refresh_token, expires_in`). Fails with `Grants::InvalidGrant` when unknown, expired, used, client or redirect mismatch, or PKCE mismatch (`base64url(SHA256(verifier)) != challenge`). Second use of a code deletes the grant.
  - `refresh(refresh_string, client_id:) -> Tokens`. Rotation: old refresh marked used, new access + refresh issued, data key rewrapped under both, previous access token deleted. Presenting an already used refresh token deletes the grant and raises `InvalidGrant`.
  - `unlock(access_string) -> Unlocked` (Struct `grant_id, credentials`) or raises `Grants::InvalidToken` (unknown, expired, bad secret). Updates `last_used_at`.
  - `revoke(token_string)`: deletes the grant of any valid token; silent on unknown tokens.
  - `delete(grant_id)`.
  - `cleanup!(now) -> [deleted_grant_ids]`: expired tokens, and grants with `last_used_at < now - 90 days`.

- [ ] **Step 1: Failing specs** (pepper fixed, clock injectable):
  - full cycle: `issue_code` → `exchange_code` → `unlock(access)` returns the original credentials hash;
  - `exchange_code` with wrong verifier, wrong redirect, wrong client, after 61 s, and second use each raise `InvalidGrant`; second use also makes `unlock` of the first access token raise `InvalidToken`;
  - `refresh` returns new tokens; old access token raises `InvalidToken`; old refresh replay raises `InvalidGrant` and kills the new access token too;
  - access token after 3601 s raises `InvalidToken`;
  - **database alone is useless:** copy every row from the store, then for each `wrapped_key` and `sealed_credentials` try `Crypto.open` with keys derived from the pepper and each stored `secret_hash` - all raise `DecryptError`;
  - `cleanup!` with `now = last_used + 90*86400 + 1` returns the grant id and removes it.
- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/server/public/grants_spec.rb` - FAIL.
- [ ] **Step 3: Implement.** Every multi-row change inside `store.transaction`.
- [ ] **Step 4: Run** - PASS.

### Task 5: OAuth clients

**Files:**
- Create: `lib/edupage/server/public/clients.rb`
- Test: `spec/server/public/clients_spec.rb`

**Interfaces:**
- Produces `Clients.new(store:, fetcher: Clients::MetadataFetcher.new)`:
  - `register(params_hash) -> Hash` (RFC 7591 response: `client_id` random 16 bytes hex, `client_id_issued_at`, `redirect_uris`, `client_name`, `token_endpoint_auth_method: "none"`, `grant_types`, `response_types`). Raises `Clients::InvalidMetadata` when `redirect_uris` is missing/empty or any URI fails `redirect_allowed?`, or when `token_endpoint_auth_method` is present and not `none`.
  - `find(client_id) -> Client` (Struct `id, name, redirect_uris, metadata_document?`) or `nil`. When `client_id` is an `https://` URL, fetch it via `fetcher` (cache in memory 10 min); the document's `client_id` must equal the URL.
  - `redirect_allowed?(uri) -> Boolean`: `https` any host; `http` only for hosts `localhost`, `127.0.0.1`, `[::1]`; no fragment.
  - `redirect_matches?(client, uri) -> Boolean`: exact string match, except loopback URIs match ignoring port (RFC 8252).
  - `claude?(redirect_uri) -> Boolean`: host in `CLAUDE_CALLBACK_HOSTS = %w[claude.ai claude.com]`.
- Produces `Clients::MetadataFetcher#call(url) -> Hash`: Net::HTTP, `https` only, 3 s open/read timeout, no redirects, body limit 16 KB, refuses hosts resolving to private, loopback or link-local addresses (`Addrinfo`/`IPAddr#private?`, `#loopback?`, `#link_local?`), JSON object required.

- [ ] **Step 1: Failing specs:** registration happy path and each rejection; CIMD fetch with WebMock (match, `client_id` mismatch rejected, redirect response rejected, 20 KB body rejected, URL resolving to `10.0.0.1` rejected by stubbing the resolver); `redirect_matches?` loopback port tolerance and exact match otherwise; `claude?("https://claude.ai/api/mcp/auth_callback")` true and `claude?("https://evil.example/cb")` false.
- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/server/public/clients_spec.rb` - FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** - PASS.

### Task 6: Edupage web login and two-factor protocol

**Files:**
- Create: `lib/edupage/web_login.rb`
- Modify: `spec/support/vcr.rb` (filter `t2fasec`, `sgn`, `edid`, `userToken`, `token`, `password` inside `rpcparams`)
- Test: `spec/web_login_spec.rb`

**Interfaces:**
- Produces `Edupage::WebLogin.new(school:, username:, password:)` (own Mechanize agent with cookie jar, `redirect_ok = false`, `Client::USER_AGENT`), `#inspect` redacted:
  - `start -> Result` runs `getToken` then `login` (`POST /login/?cmd=MainLogin&akcia=getToken|login`, body `rpcparams=<JSON>` plain, see Step 5). `Result` Struct: `status` (`:ok`, `:two_factor`), `session_id`, `userid`, `role`, `name`. Wrong password raises `Edupage::LoginError`.
  - `two_factor_info -> TwoFactorInfo` from `GET /login/twofactor` page props (`deviceNames`, `email`, `requestid`, parsed from the `var props = {...}` JSON in the page). Struct: `device_names`, `email`, `channel` (`:push` when `device_names` non-empty, else `:email`).
  - `poll -> :waiting | :expired | String secret` (`POST /login/twofactor?akcia=checkIfConfirmed`; `status == "ok"` → `data`; `data.requestexpired` → `:expired`).
  - `send_email -> :sent | Integer retry_in_seconds`; `resend_push -> true`.
  - `complete(secret_or_code) -> Result` (`login` with `t2fasec`, `"2fNoSave" => "y"`, `"2fform" => "1"`, `tu/gu/au: nil`); `isTwoFactorLogged: true` → `:ok`; `error_id == "invalid_token"` or other failure raises `Edupage::LoginError` with a Slovak-agnostic English message.

- [ ] **Step 1: Failing specs with WebMock stubs** built from the response shapes in the spec's "Two-factor login" section: plain login returns `:ok`; `need2fa: "1"` returns `:two_factor`; `two_factor_info` parses `deviceNames: ["iPhone"]` → `:push` and `[]` → `:email`; `poll` maps `fail` → `:waiting`, `ok` → secret, `requestexpired` → `:expired`; `complete` sends `t2fasec` and returns `:ok`; `inspect` contains no password.
- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/web_login_spec.rb` - FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** - PASS.
- [ ] **Step 5: Live check with the owner (blocking for Task 7's 2FA path).** Ask the owner to be ready to approve on their phone, then run a throwaway script (not committed) using `mise exec -- bundle exec ruby -I lib` that runs `start`, prints only `status`, then `two_factor_info.channel`, polls until a secret arrives, calls `complete`, and checks `Session.new(origin:, session_id:, ...).valid?` and one `GET /user/` is not a redirect. Settle and record in this task's notes: (a) whether plain `rpcparams` works or the `eqap=dz:` encoding is required (if required, implement `dz:` = base64 of raw deflate and set `eqaz=1`; if `eqacs` is then rejected, stop and report); (b) whether the web session id works with the existing `Client`/`Session`; (c) whether the 2FA endpoints also accept the session from `Client.mauth` (if yes, `LoginFlow` may skip `start` and reuse the `mauth` session). Do not print secrets.

### Task 7: Login flow, pending authorizations, rate limiter

**Files:**
- Create: `lib/edupage/server/public/rate_limiter.rb`, `lib/edupage/server/public/pending.rb`, `lib/edupage/server/public/login_flow.rb`
- Test: `spec/server/public/rate_limiter_spec.rb`, `spec/server/public/login_flow_spec.rb`

**Interfaces:**
- Produces `RateLimiter.new(limit: 5, window: 900, clock:)`: `blocked?(*keys)`, `failure!(*keys)`, `reset!(*keys)`.
- Produces `Pending.new(ttl: 600, clock:)`: `create(oauth_params) -> PendingAuth` (Struct with `id`, `csrf`, `oauth` (client_id, redirect_uri, state, code_challenge, resource, client_name), `credentials`, `sessions` (origin → mauth entry), `queue` (origins needing 2FA), `current` (WebLogin), `skipped` (origins), `done`), `find(id)`, `delete(id)`; expired entries dropped on access. Holds everything in memory only.
- Produces `LoginFlow.new(pending:, rate_limiter:, grants:, runtimes:, mauth: Client.method(:mauth), web_login: WebLogin.method(:new))`:
  - `submit_password(auth, school:, username:, password:, ip:) -> :two_factor | :done` (raises `LoginFlow::Blocked`, `LoginFlow::BadCredentials`). On success fills `auth.credentials`, `auth.sessions`, `auth.queue` (origins with `needs_2fa`), resets limiter keys.
  - `current_two_factor(auth) -> TwoFactorInfo` (starts `WebLogin` for `auth.queue.first` on first call).
  - `poll(auth) -> :waiting | :expired | :next | :done`; `submit_code(auth, code) -> :next | :done | :invalid`; `send_email(auth)`, `resend_push(auth)`; `skip(auth) -> :next | :done` (moves the origin to `skipped`).
  - `finish(auth) -> redirect_url` : raises `LoginFlow::NothingUsable` when every origin is skipped or 2FA failed; otherwise `grants.issue_code(...)` with `two_factor_origins = skipped`, seeds `runtimes.seed(grant_id, credentials, sessions)` with the usable sessions, deletes the pending entry, returns `redirect_uri` with `code` and `state` (and `iss` = issuer) appended.

- [ ] **Step 1: Failing specs** (mauth and WebLogin as doubles): wrong password → `BadCredentials`, limiter counts it, 6th attempt → `Blocked` even with the right password; non-2FA account → `:done`; `finish` returns a redirect with `code`, `state` and `iss`; two schools, one 2FA: `:two_factor`, `poll` → secret → `:done`, grant credentials list both schools and an empty `two_factor_origins`; same but `skip` → grant created with the 2FA origin in `two_factor_origins`; all schools 2FA and skipped → `NothingUsable`; pending entry gone after `finish`; pending expired after 601 s.
- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/server/public/rate_limiter_spec.rb spec/server/public/login_flow_spec.rb` - FAIL.
- [ ] **Step 3: Implement.** `submit_password` uses `ip` and `"#{username.downcase}|#{school}"` as limiter keys.
- [ ] **Step 4: Run** - PASS.

### Task 8: OAuth HTTP app and pages

**Files:**
- Create: `lib/edupage/server/public/app.rb`, `lib/edupage/server/public/views/layout.erb`, `login.erb`, `two_factor.erb`, `notice.erb`
- Modify: `lib/edupage.rb` (Zeitwerk ignore for `views`)
- Test: `spec/server/public/oauth_spec.rb`

**Interfaces:**
- Consumes: `Settings`, `Clients`, `Grants`, `LoginFlow`, `Pending`.
- Produces `Public::App < Sinatra::Base` with `App.configure_with(settings:, clients:, grants:, flow:, pending:, runtimes:)` (class-level accessors, same pattern as `Server::API.account_options`). Routes:
  - `GET /.well-known/oauth-protected-resource` and `GET /.well-known/oauth-protected-resource/mcp` → `{resource:, authorization_servers: [issuer], bearer_methods_supported: ["header"]}`.
  - `GET /.well-known/oauth-authorization-server` → `issuer`, `authorization_endpoint` (`/oauth/authorize`), `token_endpoint` (`/oauth/token`), `registration_endpoint` (`/oauth/register`), `revocation_endpoint` (`/oauth/revoke`), `response_types_supported: ["code"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none"]`, `client_id_metadata_document_supported: true`.
  - `POST /oauth/register` (JSON) → 201 or 400 `{error: "invalid_client_metadata", error_description:}`.
  - `GET /oauth/authorize`: validates `response_type=code`, client, `redirect_uri` match, `code_challenge` with `S256`, `resource` (if present must equal `settings.resource`). Invalid client or redirect → `notice.erb` with 400 (never redirect to an unverified URI). Other errors → redirect with `error=invalid_request` and `state`. Valid → `Pending#create`, render `login.erb`.
  - Client IP for the limiter: `request.ip` when `settings.trust_proxy?` (Rack honours `X-Forwarded-For`), otherwise `env["REMOTE_ADDR"]`.
  - `POST /oauth/authorize` (fields `pending_id`, `csrf`, `school`, `username`, `password`) → `LoginFlow#submit_password`; `:two_factor` → redirect `GET /oauth/authorize/two-factor?pending_id=`; `:done` → 302 to `finish`.
  - `GET /oauth/authorize/two-factor` renders `two_factor.erb` (push: spinner + polling; e-mail: code input). `POST /oauth/authorize/two-factor/poll` (JSON `{state: "waiting"|"expired"|"next"|"done", redirect:}`), `POST .../code`, `POST .../resend`, `POST .../email`, `POST .../skip`. Every POST checks `csrf`.
  - `POST /oauth/token` (form): `grant_type=authorization_code` (needs `code`, `redirect_uri`, `client_id`, `code_verifier`) or `refresh_token`. JSON `{access_token, token_type: "Bearer", expires_in: 3600, refresh_token}`; errors 400 `{error: "invalid_grant"|"invalid_request"|"unsupported_grant_type"}`. `Cache-Control: no-store`.
  - `POST /oauth/revoke` → always 200.
- Page copy (Slovak, exact strings):
  - title `Pripojenie k Edupage`;
  - client line `Prístup žiada: <client_name> (názov uvádza aplikácia sama, nie je overený)` and `Prihlásenie sa odošle na: <redirect host>`;
  - non-Claude warning (when `!clients.claude?(redirect_uri)`): `Toto nie je Claude. Pokračuj, len ak tejto aplikácii dôveruješ.`;
  - always: `Tento server si uloží tvoje heslo k Edupage, aby sa mohol prihlasovať za teba. Pokračuj, len ak dôveruješ prevádzkovateľovi tohto servera.`;
  - always: `Prístup je iba na čítanie, nič sa do Edupage nezapíše.`;
  - always: `Ak má škola dvojstupňové overenie, v ďalšom kroku ho potvrdíš v aplikácii Edupage alebo kódom z e-mailu.`;
  - push page: `Potvrď prihlásenie v aplikácii Edupage (<device names>)`; expired: `Žiadosť vypršala.` + button `Poslať znova`;
  - e-mail page: `Kód sme poslali na <masked email>` + input + `Poslať znova` (disabled with countdown when `retry_in_seconds`);
  - skip button `Preskočiť túto školu`;
  - finished/unknown pending: `Toto prihlásenie už skončilo alebo vypršalo. Začni znova v aplikácii, z ktorej si sa pripájal.`
- Polling page JS: `fetch` POST every 3 s, follow `redirect` on `done`; `<noscript>` fallback `<meta http-equiv="refresh" content="3">` on a GET that polls once.

- [ ] **Step 1: Failing rack-test specs:** metadata documents contain the exact values above; DCR happy path and 400; full flow with stubbed `Client.mauth` (no 2FA): register → authorize GET 200 contains the password warning and the non-Claude warning for `https://evil.example/cb` but not for `https://claude.ai/api/mcp/auth_callback` → POST credentials → 302 to redirect with `code`, `state`, `iss` → token exchange 200 → refresh 200 → revoke 200 → refresh 400; authorize with unregistered redirect renders 400 and no `Location`; missing `code_challenge` redirects with `error=invalid_request`; wrong CSRF 403; **Review Focus 5:** posting the same login form again after the code was issued renders the "already finished" notice with 400 and creates no second grant; 2FA path with a WebLogin double: `two-factor` page shows `iPhone`, poll returns `waiting` then `done` with redirect; e-mail channel renders the code input.
- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/server/public/oauth_spec.rb` - FAIL.
- [ ] **Step 3: Implement routes and views.** Escape every interpolated value (`Rack::Utils.escape_html`). Set `Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; form-action 'self' <redirect origin>`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` on pages.
- [ ] **Step 4: Run** - PASS.

### Task 9: Runtimes and the public MCP endpoint

**Files:**
- Create: `lib/edupage/server/public/runtimes.rb`
- Modify: `lib/edupage/server/mcp.rb`, `lib/edupage/server/public/app.rb`
- Test: `spec/server/public/runtimes_spec.rb`, `spec/server/public/mcp_spec.rb`; existing `spec/server/*` must stay green.

**Interfaces:**
- Produces `Runtimes.new(data_dir:, idle: 1800, clock:, account_builder: nil)`:
  - `seed(grant_id, credentials, sessions)` keeps the login form's sessions for the first call.
  - `with_account(grant_id, credentials) { |account| }`: builds on first use `Account.new` from seeded sessions, or `Account.login(credentials: StaticCredentials.new(...), store: MemorySessionStore.new, cache: Cache.new(root: File.join(data_dir, "cache", grant_id)))`; yields under the grant's `Mutex` (serializes all calls of one grant).
  - `evict_idle!(now)`, `forget(grant_id)` (drops runtime and `rm_rf` its cache dir).
- Modify `Server::MCP`:
  - `MCP.new(account_options: {}, public: false)`; in public mode the tool block declares `server_context:` and calls `MCP.respond(resource, arguments.except(:username), {}, account: server_context[:account_provider])`.
  - `self.respond(resource, arguments, account_options, account: nil)`: when `account` is a callable, it is called with a block receiving the account (`account.call { |acc| ... }`); when nil, today's `Edupage.account(...)` path. Error mapping unchanged, plus `TwoFactorRequiredError` → tool error text `"#{origin} vyžaduje dvojstupňové overenie. Odpoj a znova pripoj Edupage konektor a potvrď prihlásenie."` (keep the English `TwoFactorRequiredError` message for non-public mode).
  - `public_tools` cached; `build_server(server_context) -> ::MCP::Server` per request.
- `/mcp` in `Public::App` (GET, POST, DELETE): bearer from `Authorization` only (no query param). Missing/invalid/expired → 401 JSON `{error: "invalid_token"}` with `WWW-Authenticate: Bearer resource_metadata="#{issuer}/.well-known/oauth-protected-resource/mcp", error="invalid_token"`. Valid → `grants.unlock`, `account_provider = ->(&blk) { runtimes.with_account(grant_id, credentials, &blk) }`, per-request `StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true, allowed_hosts: [settings.host])`. When the account raises `LoginError` on re-login (password changed), `grants.delete` + `runtimes.forget`, answer 401 as above.

- [ ] **Step 1: Failing specs:**
  - **Isolation:** two grants for `parent-a` and `parent-b` (FakeSession origins `zsdemo` and `zsother`); `tools/call edupage_schools` with token A lists only `zsdemo`; passing `school: "zsother"` and `username: "parent-b"` with token A returns a tool error and never builds B's account; cache dirs of A and B are separate paths under `data_dir/cache`.
  - **Review Focus 1:** two threads call tools on the same grant; a spy account records enter/exit; no overlap.
  - **Review Focus 2:** `Runtimes` with no seed and a `Client.mauth` stub where the origin has `needs_2fa: true` → tool result `isError: true` with the Slovak reconnect text, HTTP 200.
  - **Review Focus 3:** expired access token → 401 and the exact `WWW-Authenticate` header.
  - **Review Focus 4:** account raises `LoginError` → 401, `grants.find` returns nil afterwards.
  - Tool list in public mode has no `username` property in any input schema.
  - Non-public `Server::MCP` specs unchanged and green.
- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/server` - FAIL (new specs).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mise exec -- bundle exec rspec` - all PASS.

### Task 10: Wiring, CLI, logging, cleanup

**Files:**
- Create: `lib/edupage/server/public.rb`, `lib/edupage/server/public/request_log.rb`
- Modify: `lib/edupage/server.rb`, `lib/edupage/cli.rb`
- Test: `spec/server/public/start_spec.rb`, `spec/server/public/request_log_spec.rb`, `spec/cli/server_spec.rb` (new or extend)

**Interfaces:**
- Produces `Public.build_app(settings) -> Rack app` (constructs Store at `File.join(data_dir, "edupage.sqlite3")`, Grants, Clients, Pending, RateLimiter, Runtimes, LoginFlow; wraps `App` in `RequestLog`) and `Public.start(host:, port:, public_url:)`: `require_sqlite!`, `Settings.from_env`, `mkdir_p data_dir` (`0700`), starts a cleanup thread (every 3600 s: `grants.cleanup!`, `runtimes.forget` for deleted ids, `runtimes.evict_idle!`, `pending` sweep), banner without any secret, `Server.run`.
- `Server.start(..., public: false, public_url: nil)` delegates to `Public.start` when `public`; never touches `Auth.token` or the config file in that case.
- CLI: `method_option :public, type: :boolean, desc: "Public multi-user mode with OAuth login (see README)"`, `method_option :public_url, type: :string, desc: "External https URL (default EDUPAGE_PUBLIC_URL)"`.
- `RequestLog`: one line per request `METHOD path status duration_ms` to `Edupage.logger.info`; path without query string.

- [ ] **Step 1: Failing specs:** `build_app` serves `/healthz` 200 and `/api/v1/schools` 404 (REST not mounted); starting without `EDUPAGE_SECRET_KEY` raises the settings error before binding; `RequestLog` output for `POST /oauth/token?code=x` with body `password=hunter2` contains neither `code=x` nor `hunter2`; `edupage server --public` passes `public: true` to `Server.start`.
- [ ] **Step 2: Run** `mise exec -- bundle exec rspec spec/server/public/start_spec.rb spec/server/public/request_log_spec.rb spec/cli` - FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mise exec -- bundle exec rspec` - all PASS.
- [ ] **Step 5: Local smoke test in a pane** (per the owner's Herdr rules): `EDUPAGE_PUBLIC_URL=http://localhost:4567 EDUPAGE_SECRET_KEY=$(ruby -rsecurerandom -e 'print SecureRandom.base64(32)') EDUPAGE_DATA_DIR=tmp/public mise exec -- bundle exec exe/edupage server --public`, then `curl -s localhost:4567/.well-known/oauth-authorization-server` shows the metadata and `curl -si localhost:4567/mcp -X POST` shows 401 with `WWW-Authenticate`.

### Task 11: Docker image and release

**Files:**
- Create: `Dockerfile`, `.dockerignore`
- Modify: `.github/workflows/release.yml`, `.github/workflows/ci.yml`

**Interfaces:** none in Ruby.

- [ ] **Step 1: Write `Dockerfile`**, minimal multi-stage:
  - `FROM ruby:3.4-slim AS build`: install `build-essential` (no-recommends), `COPY` the checkout, `gem build edupage-cli.gemspec`, `gem install --no-document ./edupage-cli-*.gem sqlite3`, remove gem caches (`/usr/local/bundle/cache`).
  - `FROM ruby:3.4-slim`: `COPY --from=build /usr/local/bundle /usr/local/bundle`; `useradd --system --uid 10001 --home /data edupage`; `mkdir /data && chown edupage /data`; `ENV EDUPAGE_DATA_DIR=/data EDUPAGE_CONFIG=/data/config.yml EDUPAGE_CACHE_DIR=/data/cache HOME=/data`; `USER edupage`; `VOLUME /data`; `EXPOSE 4567`; `HEALTHCHECK CMD ruby -rnet/http -e 'exit Net::HTTP.get_response(URI("http://127.0.0.1:4567/healthz")).is_a?(Net::HTTPSuccess)'`; `CMD ["edupage", "server", "--public", "--host", "0.0.0.0"]`.
  - `.dockerignore`: `.git`, `spec`, `docs`, `tmp`, `pkg`, `*.gem`, `mise.toml`, `.github`.
- [ ] **Step 2: Build in a pane:** `docker build -t edupage-cli:dev .` - expected success; then `docker run --rm edupage-cli:dev edupage version` prints `Edupage::VERSION`; `docker run --rm -e EDUPAGE_PUBLIC_URL=http://localhost:4567 -e EDUPAGE_SECRET_KEY=$(ruby -rsecurerandom -e 'print SecureRandom.base64(32)') -p 4567:4567 edupage-cli:dev` answers `/healthz`. Report `docker image ls edupage-cli:dev` size.
- [ ] **Step 3: Release workflow:** new job `image` with `needs: release`, `permissions: { contents: read, packages: write }`, `docker/setup-qemu-action`, `docker/setup-buildx-action`, `docker/login-action` to `ghcr.io` with `GITHUB_TOKEN`, `docker/build-push-action` with `platforms: linux/amd64,linux/arm64`, `push: true`, tags `ghcr.io/alhafoudh/edupage-cli:${{ needs.release.outputs.version }}` and `:latest`, checking out `needs.release.outputs.tag`. Skip when the version tag already has an image (`docker manifest inspect` succeeds), mirroring the idempotency of the gem job.
- [ ] **Step 4: CI:** job `docker` that runs `docker build .` on `ubuntu-latest` (no push).
- [ ] **Step 5: Validate workflow syntax:** `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); YAML.load_file(".github/workflows/ci.yml")'` - no error.

### Task 12: README

**Files:**
- Modify: `README.md` (Slovak, new section after the server section)

- [ ] **Step 1: Write the section** `## Verejný MCP server pre Claude` covering, in Slovak and without em dashes: what it does; security model in 4 to 6 sentences (heslo je šifrované kľúčom odvodeným z tokenu, ktorý má len klient; samotná databáza nič neprezradí; server heslo dešifruje iba počas požiadavky; iba na čítanie); env vars table (`EDUPAGE_PUBLIC_URL`, `EDUPAGE_SECRET_KEY` with generation command `openssl rand -base64 32`, `EDUPAGE_DATA_DIR`, `EDUPAGE_TRUST_PROXY`); a `docker-compose.yml` for Portainer:

```yaml
services:
  edupage:
    image: ghcr.io/alhafoudh/edupage-cli:latest
    restart: unless-stopped
    environment:
      EDUPAGE_PUBLIC_URL: https://edupage-mcp.example.com
      EDUPAGE_SECRET_KEY: ${EDUPAGE_SECRET_KEY}
      EDUPAGE_TRUST_PROXY: "1"
    volumes:
      - edupage-data:/data
    ports:
      - "127.0.0.1:4567:4567"
volumes:
  edupage-data:
```
  plus a minimal Caddy example (`edupage-mcp.example.com { reverse_proxy 127.0.0.1:4567 }`), HTTPS required; how to add `https://<host>/mcp` in Claude (Settings → Connectors → Add custom connector); 2FA behaviour (push: potvrdiť v aplikácii, e-mail: zadať kód, po vypršaní session znova pripojiť konektor); note that rotating `EDUPAGE_SECRET_KEY` disconnects everyone.
- [ ] **Step 2: Check** `grep -nP '[\x{2013}\x{2014}]' README.md` prints nothing new.
- [ ] **Step 3: Final full run:** `mise exec -- bundle exec rspec` - all PASS. Then stop and tell the owner the work is ready for a single commit.
