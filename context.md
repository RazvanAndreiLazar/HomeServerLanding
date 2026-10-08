# Context: home server gateway (Auth)

Handoff from a planning/implementation session. Read this before changing anything in `Auth/`.

## Working rules (from the owner)

- **Change only what you are told to change, and only when told.** Do not touch other files,
  do not "tidy up" or update related files unasked. When a change would logically need edits
  elsewhere, say so and wait.
- When asked to explain or plan ("don't write code yet"), explain only.
- Prefer targeted, minimal edits over rewrites.
- Flag uncertainty explicitly; say what is unverified and how to verify it.
- Be concise. Honest assessments over agreeable ones.
- The repository may become public: no machine names, IPs, secrets or hashes in committed files.

## Server

- Debian 13 on an old PC (i5-750, 12 GB RAM, ~125 GB SSD for OS, ~550 GB HDD for data, GTX 1050 Ti).
- ISP behind CGNAT, so all remote access is via **Tailscale only** (server is also an exit node).
  No ports forwarded on the router.
- Docker + Compose. Immich runs from its own compose file (container `immich_server`, port 2283).
- Users: a family (each member gets an Authelia account, a Linux account and app accounts) plus guests.

## Architecture (current, working)

```
device in tailnet
 ├─ https://<SERVER_NAME>/   tailscale serve --bg http://127.0.0.1:8080  →  Caddy :8080
 │     /            landing page (public; guests see it)
 │     /config.json machine-specific values for the landing page (from .env, via Caddy)
 │     /auth/*      Authelia (login portal, API, OIDC provider)
 │     /whoami/*    test app behind forward_auth (to be removed after setup)
 └─ https://<IMMICH_HOST>/   Tailscale Service svc:immich (endpoint tcp:443)
                             tailscale serve --service=svc:immich --https=443 http://127.0.0.1:2283
                             Immich logs in via Authelia (OpenID Connect)
```

`<SERVER_NAME>` = server's MagicDNS name (`server.<tailnet>.ts.net`), `<IMMICH_HOST>` = `immich.<tailnet>.ts.net`.
The server is tagged `tag:server`; services use `tag:server-svc` with an autoApprover.

## Repository layout (`<repo>/Auth/`)

```
.gitignore                          ignores .env, secrets/, users_database.yml, db.sqlite3, notification.txt
landing/index.html                  static landing page (whole folder is public via Caddy)
gateway/
  README.md                         linear setup guide (steps 1-10 + day-to-day, backup, limitations)
  .env.example                      SERVER_NAME, LAN_IP, IMMICH_HOST
  docker-compose.yml                caddy:2, authelia/authelia:4.39 (pinned), traefik/whoami
  caddy/Caddyfile
  authelia/config/configuration.yml
  authelia/config/users_database.example.yml
```

Compose runs from `Auth/gateway`; it mounts `../landing` at `/srv/landing:ro`.

## Key configuration facts

- **.env → config:** Caddy reads `{$SERVER_NAME}`/`{$LAN_IP}`; Authelia uses
  `X_AUTHELIA_CONFIG_FILTERS=template` so `configuration.yml` uses `{{ env "SERVER_NAME" }}`,
  `{{ env "IMMICH_HOST" }}` and `{{ secret "/secrets/..." }}`.
- **Caddy:** `admin off`; `trusted_proxies static private_ranges`; snippet `(original_request)` sets
  `X-Forwarded-Proto https` and `X-Forwarded-Host {$SERVER_NAME}` (tailscale serve terminates TLS).
  Caddy reads the Caddyfile only at start: restart after edits.
- **Authelia:** served under `/auth` (`server.address: tcp://:9091/auth`); file user backend
  (argon2, `watch: true`); password reset disabled; `access_control.default_policy: deny`
  (each protected path needs a rule; group `family`, `one_factor`); session cookie on the exact
  `SERVER_NAME` (not `*.ts.net`), expiration 1h, inactivity 30m, remember_me 30d;
  regulation 5 tries / 10m / ban 15m; SQLite storage; filesystem notifier.
  Sessions are in memory (no Redis): restarting Authelia logs everyone out.
- **Secrets** (in `gateway/authelia/secrets/`, generated on the server, never committed):
  `jwt`, `session`, `storage`, `oidc_hmac`, `oidc_jwks.pem` (RSA 2048), `immich_client_digest`
  (pbkdf2-sha512 digest; the plain client secret lives only in Immich's settings).
- **OIDC client `immich`:** confidential, `one_factor`, `consent_mode: implicit`,
  redirect URIs `https://<IMMICH_HOST>/auth/login`, `/user-settings`, `app.immich:///oauth-callback`,
  scopes openid/profile/email, `userinfo_signed_response_alg: none`,
  `token_endpoint_auth_method: client_secret_post`.
- **Immich OAuth settings:** issuer `https://<SERVER_NAME>/auth/.well-known/openid-configuration`,
  client ID `immich`, RS256 / profile signing `none`, auto register off, auto launch on.
  Existing accounts were linked manually (Account Settings → OAuth → Link). Password login still on.

## Landing page (`landing/index.html`) behaviour

- Reads `/config.json` (`serverName`, `lanIp`); derives the tailnet from `serverName`.
- `appList(TAILNET, LAN)`: one entry per app (`name`, `icon`, `description`, `url`, optional
  `guestUrl`, optional `lanUrl`). Immich `guestUrl` = `https://immich.<tailnet>/auth/login?autoLaunch=0`
  so guests see Immich's own login form instead of being auto-sent to Authelia.
- Login state: `GET /auth/api/state` (`authentication_level > 0` = logged in), display name from
  `GET /auth/api/user/info`. Greeting appends the display name. Tiles render after `authReady`.
- Top-right button: guests → "Log In" → `/auth/?rd=<origin>/`. Logged in → "Log Out":
  1. `POST https://immich.<tailnet>/api/auth/logout` with `mode: no-cors, credentials: include`
     for each entry in `ssoLogouts(tailnet)` (4 s timeout each),
  2. `POST /auth/api/logout`,
  3. `location.replace("/")`.
- Status dots: rough reachability via `no-cors` fetch.
- `/auth/api/*` is Authelia's internal (unversioned) API; re-test after Authelia upgrades.

## Decisions and rejected options

- Chosen: Caddy + Authelia (file backend) instead of LLDAP/SSSD/Redis (too heavy for a family)
  and instead of a fully custom auth service (auth code to maintain, PAM needs shadow access).
- Custom login UI calling Authelia's API (user cards from users file): **tabled for later**.
  If built: browser calls `/auth/api/firstfactor` directly (not proxied through a backend, to keep
  per-IP brute-force protection per client); backend only serves the user list (no hashes, filter by group).
- Rejected: `forward_auth` in front of all of Immich (breaks the mobile app).
- Rejected: "pre-logging" users into all apps at Authelia login (OIDC is pull-based; would need
  hidden frames/redirect chains, fragile and version-dependent, more live sessions).
- Logout: no OIDC single logout between Authelia 4.39 and Immich (as far as known), hence the
  browser-side logout chain on the landing page. Fallback if it fails: route Immich through a
  second Caddy listener and handle logout on the Immich host.

## Unverified / open items

- Whether the cross-host Immich logout actually sends Immich's cookie (depends on browser treating
  `server.<tailnet>.ts.net` and `immich.<tailnet>.ts.net` as same-site). Test: log out from the
  landing page, then open Immich; it should require login.
- Whether Immich honours `?autoLaunch=0` (test as guest in a private window).
- Immich's own Log out button only ends Immich's session; with auto launch on, the user is logged
  straight back in via Authelia. Not solved yet.
- Unknown whether the server's `configuration.yml` contains an explicit
  `server.endpoints.authz.forward-auth` block (possibly added while fixing a 404), and whether
  Immich's compose needed `extra_hosts` for `<SERVER_NAME>`. Check the live server before assuming.
- `whoami` test service and its Caddy/Authelia rules are still present; remove when told.
- Authelia session expiry does not end app sessions; only explicit logout does.

## Possible next steps (only when asked)

- Group-based app visibility (needs a protected `/me` endpoint in Caddy returning `Remote-*` headers).
- File Browser per user (`/files`, one instance per member running as their UID, mounting their `/home`).
- Custom login UI with user cards.
- Second HDD + ZFS mirror and off-site backup (data-durability goal not yet met with one HDD).
