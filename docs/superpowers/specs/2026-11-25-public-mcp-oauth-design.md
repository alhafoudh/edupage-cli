# Public MCP server with Edupage login over OAuth

Date: 2026-11-25
Status: draft, waiting for approval

## Intent

Make `edupage server` deployable on a public server so anyone who has its URL can add it
to Claude (claude.ai, desktop, mobile) as a custom connector and get read-only access to
their own Edupage account, without installing anything locally.

Claude connectors authenticate with OAuth. Instead of a separate user database, the
OAuth authorization screen asks for the Edupage username, password and school. The
server checks them against Edupage, stores them encrypted, and issues tokens. From then
on every MCP tool call runs as that Edupage account.

The owner deploys it himself with Docker Compose in Portainer. The repo ships the
Dockerfile, the published image and README examples; the deployment itself is out of
scope.

## Goals

- `edupage server --public` serves MCP over Streamable HTTP (the existing `/mcp`
  transport) behind an OAuth 2.1 authorization server built into the same process.
- Works as a Claude custom connector with no manual client setup.
- Anyone with the URL can connect; the login form is the only "registration".
- Strict account isolation: a token can only ever reach the Edupage account it was
  issued for.
- Stolen database alone does not reveal any Edupage password.
- Docker image published on every release; README (Slovak) documents a
  `docker-compose.yml` for Portainer.

## Non-goals

- Background access to Edupage. The server only talks to Edupage while handling an MCP
  call or the login form. No notifications, no polling.
- REST API in public mode. `--public` serves MCP, OAuth and `/healthz` only.
- Two-factor login outside the OAuth login form. 2FA is completed interactively while
  the user is at the form (see "Two-factor login"); the server never asks for a second
  factor during an MCP call.
- User management, admin UI, allow-lists, billing.
- Deployment automation (Kamal, TLS, reverse proxy config) beyond README examples.

## Anti-goals (failure even if it works)

- Any path where token A reads data of account B, including through shared caches,
  shared Edupage sessions or tool arguments.
- Writing anything to Edupage. The read-only rule from CLAUDE.md applies unchanged.
- Passwords, tokens, session ids or form bodies in logs.
- Plain-text or server-decryptable passwords at rest.
- Becoming a password-guessing proxy against Edupage.

## Constraints and facts from the current code

- `Server::MCP` already builds tools from `Registry` and serves them through
  `MCP::Server::Transports::StreamableHTTPTransport` (stateless, JSON responses). This
  stays.
- `Server::API` (Sinatra) mounts `/mcp` and the REST routes behind one static bearer
  token (`Server::Auth`). Public mode needs per-request identity instead.
- `Edupage.account` memoizes one global `Account` (`@account ||=`). Public mode must
  never call it; it builds an `Account` per grant.
- `SessionStore` is a JSON file keyed by username; `Session#with_cursor` uses its file
  lock because Edupage's "current child / current year" cursor is global to a session.
  Public mode needs an in-memory store per grant and a per-session mutex.
- `Cache` keys are `(origin, year, student_id, resource)`, without the account. Two
  parents of the same child would share entries. Public mode gives each grant its own
  cache root (or disables the file cache and uses an in-memory per-grant cache).
- `Credentials` resolves from env/keychain. Public mode needs a plain in-memory
  credentials object built from decrypted values.
- MCP tools accept `username` and `school` arguments today. In public mode `username`
  is removed from the schema and ignored; `school` may only select among schools the
  account's login returned.
- The `mcp` gem (1.5.1) has OAuth support only on the client side. The server side is
  ours to write.
- `sqlite3` is a native gem. Adding it as a hard gemspec dependency would force a C
  build on every CLI/Homebrew user.

## Approaches considered

1. **`--public` mode in this gem (chosen).** OAuth endpoints, account store and
   per-token isolation added to the existing Sinatra server; tools, Registry and
   parsers untouched; Dockerfile in this repo, image published by the release workflow.
   One version, one release. Cost: hosting code ships inside the CLI gem.
2. **Separate project using the gem as a library.** Keeps the CLI clean, but two repos
   and two release trains; every tool change needs a gem release first.
3. **External identity provider (Keycloak, Auth0) in front.** Rejected: login must be
   verified against Edupage itself, which these products do not do without a custom
   plugin, and the password would pass through a third party.

The owner picked approach 1 with the flag name `--public`. Within it, the OAuth server
is written by hand rather than with a library (Doorkeeper is Rails-only; the needed
subset is small and testable).

## Design

### Process and configuration

`edupage server --public` (in the image: `--host 0.0.0.0`) requires:

- `EDUPAGE_PUBLIC_URL` (or `--public-url`): external https base URL, used as the OAuth
  issuer and resource identifier. Startup fails without it.
- `EDUPAGE_SECRET_KEY`: server pepper, at least 32 random bytes (base64 or hex). Mixed
  into every key derivation. Startup fails without it. Rotating it invalidates all
  grants (users reconnect).
- `EDUPAGE_DATA_DIR` (default `/data` in the image): SQLite database and per-grant
  cache.
- `EDUPAGE_TRUST_PROXY` (default off): when on, client IP for rate limiting comes from
  `X-Forwarded-For`.

Without `--public` the server behaves exactly as today.

### Endpoints in public mode

| Path | Purpose |
|---|---|
| `GET /.well-known/oauth-protected-resource` (and `/mcp` suffixed variant) | RFC 9728 metadata pointing at the issuer |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata: endpoints, `S256` only, grant types `authorization_code` and `refresh_token`, `token_endpoint_auth_methods_supported: ["none"]`, `client_id_metadata_document_supported: true` |
| `POST /oauth/register` | RFC 7591 dynamic client registration (public clients only) |
| `GET /oauth/authorize` | Login form |
| `POST /oauth/authorize` | Verify Edupage login, issue authorization code, redirect |
| `POST /oauth/token` | Code exchange and refresh with rotation |
| `POST /oauth/revoke` | RFC 7009 revocation, deletes the grant |
| `GET/POST/DELETE /mcp` | MCP; 401 with `WWW-Authenticate: Bearer resource_metadata="..."` when the token is missing or invalid |
| `GET /healthz` | Unchanged |

REST routes are not mounted.

Clients are identified either by a registered `client_id` (DCR) or by an https URL
`client_id` pointing to a Client ID Metadata Document, which the server fetches (with
size limit, timeout, no redirects to private addresses) to read `redirect_uris`.
Supporting both covers current and older Claude clients.

Any client is allowed (owner's decision): any https redirect URI and loopback
(`http://localhost`, `http://127.0.0.1`, `http://[::1]`, any port) redirects. This
accepts the phishing risk of open registration (an attacker registers a client named
"Claude" with their own redirect and sends a parent a link to the real login page);
the login form mitigates it with warnings, see below.

Redirect URIs must match exactly what the client registered. PKCE `S256` is mandatory.
The `resource` parameter (RFC 8707), when sent, must equal the server's `/mcp` URL.

### Login form

Server-rendered HTML, no JavaScript needed. Fields: school (subdomain, e.g. `zsxyz`),
username, password. Text in Slovak.

Warnings shown on every login form (owner's decision):

- Which client is asking: client name as registered (marked as self-declared, not
  verified) and, prominently, the host the token will be sent to. If that host is not a
  known Claude callback host, a strong warning: "Toto nie je Claude. Pokračuj, len ak
  tejto aplikácii dôveruješ."
- That this server does not store the password, only the Edupage login session, and
  that the connector has to be reconnected when it expires.
- That access is read-only.
- That schools with two-factor login will ask for approval in the Edupage app or an
  e-mailed code in the next step.

On submit:

1. Rate limit check (per IP and per username+school): for example 5 failures per 15
   minutes, then a lock-out message. Limits held in memory.
2. CSRF token check (form is bound to the pending authorization request).
3. `Client.mauth` against Edupage. Wrong password: error on the form, nothing stored.
4. For every school with `needs_2fa`, run the two-factor step below while the user is
   still on the form. A school whose 2FA the user skips or fails stays on the grant
   but unavailable; tool calls for it return the existing `TwoFactorRequiredError`
   message. If no school ends up usable, nothing is stored.
5. Create the grant and redirect to the client with `code` and `state`.

### Two-factor login

Observed on 2026-11-25 from a HAR of the web login at a 2FA-enabled school (zssamorin,
parent account). The web login (`/login/?cmd=MainLogin`) works like this:

1. `akcia=getToken` with `{username, edupage}` returns a `token`.
2. `akcia=login` with `{username, password, userToken, edupage}` returns `session`,
   `need2fa: "1"` and `redirectUrl: "/login/twofactor?"`. The session is not usable
   yet.
3. `GET /login/twofactor` renders props: `deviceNames` (e.g. `["iPhone"]`), `email`
   (masked target for codes) and `requestid`. Edupage has already sent a push to the
   user's Edupage mobile app.
4. Either:
   - **App approval:** poll `POST /login/twofactor?akcia=checkIfConfirmed` (the web
     polls every 3 s). It returns `{"status":"fail"}` until the user approves in the
     app, then `{"status":"ok","data":"<secret>"}`.
   - **E-mail code:** `POST /login/twofactor?akcia=sendEmail` sends a numeric code
     (response may carry `retryInSeconds` when throttled); the user types it.
   - `akcia=resendNotifs` re-sends the push.
5. `akcia=login` again with `{t2fasec: <secret or code>, "2fNoSave": "y",
   "2fform": "1"}` returns `isTwoFactorLogged: true`, `need2fa: null` and the same
   `session` id, which is now fully usable.

Web requests wrap parameters as `eqap=dz:<base64 raw-deflate>` and responses as
`eqz:<base64>`. Whether plain form posts are accepted too is for the builder to test.

The current code logs in through the mobile endpoint `mauth`, which only exposes the
`need2fa` flag. The builder must establish whether the 2FA endpoints accept the
`mauth` session, or whether 2FA schools need the web login above end to end, and that
the resulting session id works with the existing `Session` and parsers.

In the OAuth login form:

- After the password step, show a page per 2FA school, chosen the same way the
  Edupage web does it:
  - `deviceNames` non-empty (push): the Edupage app shows a code that the user types
    in (confirmed live on 2026-11-25: `checkIfConfirmed` kept answering `fail`, the
    login completed with the code from the app as `t2fasec`). Show "Zadaj kód z
    aplikácie Edupage (iPhone)" with a code input, and keep polling in the background
    in case the app approves directly. No e-mail option (owner's decision). If
    `checkIfConfirmed` answers `data.requestexpired`, show "žiadosť vypršala" with a
    button that re-sends (`resendNotifs`).
  - `deviceNames` empty (e-mail): show the masked address and a code input. Call
    `sendEmail` right away (whether Edupage sends it on its own is unclear); it may
    answer `retryInSeconds`, shown as a countdown on a "Poslať znova" link.
- The browser polls our server (small JS, or meta refresh as a fallback); our server
  polls `checkIfConfirmed` for it, never faster than every 3 s. Timeout after
  5 minutes with a retry option.
- On success, continue to the next 2FA school or to the redirect.
- The pending Edupage login state for this step lives only in memory, bound to the
  pending authorization request, and expires with it.

Edupage issues only a session id (no refresh token); its lifetime is unknown and will
not be measured up front (owner's decision).

**Session only, no password (owner's decision, 2026-11-25, replaces the earlier
"store the password" design):** the password lives only in memory while the login form
runs and is never stored. The grant stores the Edupage session of every connected
school (session id, user id, role, name), sealed like everything else. When a session
expires, the server does not log in again: that school's tool calls answer an error
telling the user to reconnect the connector, which re-runs the OAuth login (including
2FA). This holds for schools with and without 2FA alike, and the stored sessions
survive server restarts.

Verified live on 2026-11-25: Edupage asks for a separate 2FA code per school and per
login, even with a shared cookie jar and without `2fNoSave`; it never remembers the
device. The login response also carries `edid` and `sgn`, and the login request has
empty `tu`/`gu`/`au` fields; unexplored and not part of this design.
### Grants, tokens and encryption

One grant = one connected Claude client for one Edupage login.

Tokens are opaque strings `<id>.<secret>` (secret: 32 random bytes, base64url). The
database stores only `SHA-256(secret)` for lookup and constant-time comparison.

Credential encryption:

- At login, generate a random data key `K` per grant and encrypt
  `{username, school, schools, two_factor_origins, sessions}` (no password) with
  AES-256-GCM under `K`.
- `K` is never stored in clear. It is stored wrapped (AES-256-GCM) under keys derived
  with HKDF-SHA256 from `EDUPAGE_SECRET_KEY` and a token secret:
  - wrapped by the authorization code secret until the code is exchanged,
  - then wrapped by the current access token secret and by the current refresh token
    secret.
- Every MCP call unwraps `K` with the presented access token and decrypts the stored
  sessions in memory.
- Refresh: unwrap with the refresh token, issue new access + refresh tokens, re-wrap
  `K` under both, delete the old wrappings. The old refresh token is dead after one use
  (rotation). Replaying a used refresh token revokes the whole grant.

Consequence: no password is ever stored, and the database alone, or the database plus
the server pepper, cannot reveal the Edupage sessions. An attacker needs a live token,
which already grants the same access.

Lifetimes: authorization code 60 s, single use. Access token 1 hour. Refresh token
90 days, renewed on every refresh. Grants unused for 90 days are deleted by a periodic
cleanup inside the process.

Storage: SQLite in `EDUPAGE_DATA_DIR`. Tables: `clients` (DCR registrations),
`grants` (id, client_id, encrypted credentials, school origins, created/last_used),
`tokens` (grant_id, kind, hash, wrapped key, expires_at). `sqlite3` is a soft
dependency: required only by `--public`, installed in the Docker image, and missing it
produces a clear startup error.

### Per-request account and isolation

For each MCP request:

1. Authenticate the bearer token, find the grant, unwrap `K`, decrypt credentials.
2. Get or build an `Account` for this grant from an in-process registry keyed by
   grant id. The account uses:
   - a credentials object without a password (no env, no keychain); any attempt to
     log in again raises `SessionExpiredError`,
   - sessions built from the grant's sealed sessions, in an in-memory store owned by
     the grant (never shared with another grant),
   - a cache rooted at `EDUPAGE_DATA_DIR/cache/<grant id>` (or in-memory),
   - a per-session mutex replacing the file lock for cursor switches.
3. Run the tool through the same `Registry` path as today, but with `username`
   removed from the schema and `school` restricted to the grant's schools.

An expired Edupage session is not re-established: the tool answers "Prihlásenie do
Edupage pre <school> vypršalo. Odpoj a znova pripoj Edupage konektor." and the grant
stays (other schools may still work).

Entries in the in-process registry are evicted after a period of inactivity (e.g.
30 minutes); the next call rebuilds them from the sealed sessions.

The tool handler needs the grant for the current request. In mcp 1.5.1
`server_context` is fixed when the `MCP::Server` is built and the transport never sees
the caller, so build a small `MCP::Server` (and stateless transport) per request with
the grant in its `server_context`. Tool definitions are built once and reused. No
global holds the grant.

### Logging

Log method, path, status, duration and grant id only. Never request bodies, query
strings of `/oauth/*`, `Authorization` headers, tokens, passwords or Edupage session
ids.

### Docker

- `Dockerfile` in the repo root, minimal and multi-stage (owner's requirement): a
  build stage on `ruby:3.4-slim` with build tools compiles the gem and its native
  extensions (`sqlite3`); the runtime stage on `ruby:3.4-slim` copies only the
  installed gems, no compilers, no apt caches, no docs. Runs as a non-root user,
  `VOLUME /data`, `EXPOSE 4567`, `HEALTHCHECK` on `/healthz`, default command
  `edupage server --public --host 0.0.0.0`.
- `.dockerignore`.
- Release workflow builds and pushes `ghcr.io/alhafoudh/edupage-cli:<version>` and
  `:latest` (amd64 and arm64) when `Edupage::VERSION` changes, next to the gem.

### README (Slovak)

New section on public hosting:

- what it does and the security model in a few sentences (what is stored, that the
  database alone reveals nothing, read-only),
- `docker-compose.yml` example for Portainer (image, env vars, volume, port),
- note that HTTPS via a reverse proxy is required, with a minimal example (for example
  Caddy or Traefik labels),
- how to add the URL in Claude as a custom connector,
- how 2FA schools work (approve in the app or enter the e-mailed code during
  connecting; reconnect when Edupage asks again).

### Testing

- rack-test: full OAuth flow (DCR and CIMD client, PKCE, code exchange, refresh
  rotation, refresh replay revokes grant, revoke endpoint, wrong redirect URI, missing
  PKCE, expired code).
- Isolation: two grants for two accounts; token A can never get data of account B,
  including via `school` argument and via the cache directory.
- Crypto: database dump without tokens cannot decrypt credentials; rewrap on refresh.
- Login form: wrong password stores nothing; rate limit; CSRF.
- Edupage login through VCR cassettes with the existing filtering rules.
- Without `--public`, existing server specs pass unchanged.

## Decided by the owner

- Anyone with the URL can connect; no allow-list.
- Any OAuth client may register (not only Claude); the login form warns about
  non-Claude clients and about the password being stored.
- Two-factor schools are supported interactively in the OAuth login form (app approval
  with polling, or e-mail code), based on the owner's HAR capture.
- Accounts must be strictly isolated.
- Edupage is accessed only during MCP calls, never in the background.
- Approach 1, flag name `--public`.
- Transport is Streamable HTTP (the owner's "SSE" meant this).
- Deployment by the owner via Portainer + Docker Compose; repo provides Dockerfile and
  README examples.

## My calls (owner can override)

- REST API disabled in public mode.
- Credentials encrypted under keys derived from tokens plus a server pepper.
- SQLite as a soft dependency instead of a gemspec dependency.
- Token lifetimes and 90-day inactivity cleanup.
- Login page in Slovak.
- Image published to GHCR by the existing release workflow.

## Left to the builder

- Exact HTML/CSS of the login page.
- Module and file layout under `lib/edupage/server/`.
- In-memory vs per-grant file cache.
- Exact rate-limit numbers and eviction timeouts.
