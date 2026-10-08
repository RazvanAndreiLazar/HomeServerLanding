# Decisions and open items

## Chosen

- **Caddy + Authelia (file backend)**, not LLDAP/SSSD/Redis (too heavy for a family) and not a
  fully custom auth service (auth code to maintain; PAM needs shadow access).
- **Remote access via Tailscale only.** The ISP uses CGNAT; no ports are forwarded. HTTPS is
  terminated by `tailscale serve`, so Caddy speaks plain HTTP on `127.0.0.1:8080`.
- **Apps with their own login get their own address** (Tailscale Service, direct to the app)
  and log in via OIDC. Apps without a login go on a path of the main address behind `forward_auth`.
- **Custom login page.** Authelia 4.39 can't load custom CSS, so `web/login` replaces its portal
  page for a consistent look. Caddy serves it at `/auth/`, so Authelia's redirects (with `rd`
  and OIDC flow parameters) land on it unchanged. The browser calls `/auth/api/firstfactor`
  directly (not through a backend), so Authelia's per-IP brute-force protection keeps working.
  Authelia's portal stays reachable at `/auth/?portal=1`.
- **One app list** (`web/apps.json`) drives both the tiles and the logout chain.

## Rejected

- `forward_auth` in front of all of Immich: breaks the mobile app.
- "Pre-logging" users into all apps at Authelia login: OIDC is pull-based. It would need
  hidden frames or redirect chains, which are fragile, version-dependent, and leave more live sessions.
- Injecting CSS into Authelia's page via Caddy: needs a custom Caddy build, and Authelia's
  generated class names change between versions.
- Routing every Tailscale Service through Caddy: kept direct for now. It would centralise
  routing and allow logout handling on each app's host. Revisit if the logout chain fails.

## Open items

- **Login field names.** `web/assets/login.js` sends `targetURL`, `requestMethod`, `flow`,
  `flowID`, `subflow` (from query `rd`, `rm`, `flow`, `flow_id`, `subflow`). This is unverified
  against a live 4.39 OIDC login. Check: open Immich logged out, then compare the query on
  `/auth/` and the fallback portal's `firstfactor` request in the network tab.
- **Ban message.** Authelia may answer a banned login with the same 401 as a wrong
  password. Then the "too many attempts" text never shows, and the 401 text mentions the block instead.
- **Cross-host logout.** Whether the browser sends Immich's cookie with the blind logout
  request depends on it treating `server.<tailnet>.ts.net` and `immich.<tailnet>.ts.net` as
  same-site. Test: log out on the landing page, then open Immich; it should ask for login.
- **`?autoLaunch=0`.** Unverified that Immich honours it (test as a guest in a private window).
- **Immich's own Log out** ends only Immich's session. With auto launch on, the user is logged
  straight back in via Authelia. Not solved.
- **Authelia session expiry** does not end app sessions; only an explicit logout does.
- **Empty `access_control.rules`.** Check that Authelia starts without warnings now that the
  `whoami` rule is gone.

## Possible next steps

- Group-based app visibility: a protected `/me` route in Caddy returning the `Remote-*`
  headers, plus a `groups` field in `apps.json`.
- File Browser per user (`/files`, one instance per member running as their UID, mounting their `/home`).
- User cards on the login page (backend serves the user list from the users file: no hashes,
  filtered by group).
- Second HDD + ZFS mirror and off-site backup.
