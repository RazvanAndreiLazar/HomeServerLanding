# Uptime Kuma

Server monitoring (is each service up, how fast does it answer, notifications). It runs from this
folder's `docker-compose.yml` and has its own address, `https://<KUMA_HOST>/`
(`kuma.<tailnet>.ts.net`), as a Tailscale Service. Only Authelia users in the group `admins`
get in.

Kuma has no OpenID Connect login, so [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/)
sits in front of it: it logs in through Authelia (single sign-on, like Immich and OpenCloud) and
only then passes requests on to Kuma. Kuma itself is not published on any port, and its own login
is turned off (step 4).

```
https://<KUMA_HOST>/   tailscale serve --service=svc:kuma → 127.0.0.1:4180
  oauth2-proxy         no session → login at https://<SERVER_NAME>/auth
  └─ group admins  →   http://kuma:3001 (compose network only)
```

| Piece | Where |
|---|---|
| Containers, settings | `apps/kuma/docker-compose.yml`, `.env` (from `.env.example`, not committed) |
| OIDC client + policy `admins_only` | `apps/kuma/authelia-clients.yml`, already in `gateway/authelia/config/configuration.yml` |
| Client secret digest | `gateway/authelia/secrets/kuma_client_digest` (not committed; `setup.sh` creates it) |
| Host name for Authelia | `KUMA_HOST` in `gateway/.env` (`setup.sh` adds it) |
| Landing page tile + logout URL | `web/apps.json` (entry `kuma`) |

## Who gets in

The group `admins`, checked twice:

1. Authelia: the client `kuma` uses the authorization policy `admins_only` (`default_policy: deny`,
   `group:admins` → `one_factor`). Anyone else is refused on the login page.
2. oauth2-proxy: `OAUTH2_PROXY_ALLOWED_GROUPS=admins`, from the `groups` claim.

Add `admins` to your own entry in `gateway/authelia/config/users_database.yml` (keep `family`
too). Authelia reloads the file by itself. Everyone sees the tile on the landing page; non-admins
are refused when they open it.

## Order after an update

`gateway/authelia/config/configuration.yml` now refers to `/secrets/kuma_client_digest` and
`gateway/docker-compose.yml` needs `KUMA_HOST` in `gateway/.env`. Until both exist, `docker compose`
in `gateway/` refuses to run and Authelia won't start. Run `setup.sh` (step 2) **before** restarting
the gateway; it creates both and restarts Authelia itself.

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `kuma`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).

## 2. Start Kuma

```bash
cd apps/kuma
./scripts/setup.sh /srv/kuma/data
sudo docker compose logs -f
```

The argument is Kuma's data folder (its SQLite database: monitors, history, settings), an absolute
path outside the repository; leave it out to be asked. The script

1. writes `.env` (after showing a summary) and generates oauth2-proxy's cookie secret,
2. generates the client secret: the plain one goes into `.env` (oauth2-proxy needs it), the digest
   into `gateway/authelia/secrets/kuma_client_digest`,
3. adds `KUMA_HOST` to `gateway/.env` and recreates Authelia if either was new
   (this logs everyone out: sessions are kept in memory),
4. creates the data folder and checks that a container can reach Authelia,
5. starts Kuma and oauth2-proxy.

Running it again reuses `.env` and the digest. To check Authelia:
`cd gateway && sudo docker compose logs --tail=20 authelia` should end with "Startup complete".

## 3. Publish it

```bash
sudo tailscale serve --service=svc:kuma --https=443 http://127.0.0.1:4180
sudo tailscale serve status
```

If the service shows "Pending approval" in the admin console, approve it once.

## 4. First run

1. Open `https://<KUMA_HOST>/` as an admin. You go through the gateway login page, then land on
   Kuma's setup.
2. Choose the embedded SQLite database and create Kuma's local admin account. Keep its password
   (password manager); it is needed to turn Kuma's login back on.
3. Settings → Security → Disable Auth. From now on oauth2-proxy is the only login, so admins
   don't log in twice.

## 5. Test

1. Admin: `https://<KUMA_HOST>/` opens Kuma after the gateway login (or straight away when already
   logged in on the landing page).
2. A family member without `admins`: Authelia refuses the login for Kuma.
3. Monitors for the other apps: Kuma checks from inside its container, so `https://<SERVER_NAME>/`
   and `https://<app>.<tailnet>.ts.net/` need the same name resolution as oauth2-proxy (see
   `extra_hosts` in `docker-compose.yml` if they report a DNS error).

## Logout

The landing page's "Log Out" ends the Authelia session and then sends a blind
`POST https://<KUMA_HOST>/oauth2/sign_out` (the `logoutUrl` in `web/apps.json`), which clears
oauth2-proxy's cookie. The order matters: sign_out redirects to `/`, and the request follows that
redirect into a new login. With the Authelia session still alive, that login would succeed
silently and leave a fresh Kuma session behind (see `logOut()` in `web/assets/common.js`).
oauth2-proxy's own session lasts up to 24 hours (`OAUTH2_PROXY_COOKIE_EXPIRE`), independent of
Authelia's.

## Backup

`KUMA_DATA_DIR` (database) and `.env`. Stop the containers for a consistent copy
(`sudo docker compose stop`). The digest in `gateway/authelia/secrets/` is backed up with the
gateway; if it is lost, delete `KUMA_CLIENT_SECRET` from `.env` and run `setup.sh` again.

## Notes and unverified items

- Unverified: whether the browser sends oauth2-proxy's cookie on the cross-host logout request
  (same open question as Immich, see [decisions.md](../../docs/decisions.md#open-items)). Test: log
  out on the landing page, then open Kuma; it should ask for login.
- Unverified on the server: Kuma's live updates (socket.io websocket) through oauth2-proxy.
  oauth2-proxy proxies websockets, so this is expected to work. If the dashboard stays empty, check
  the browser console.
- `/api/push/` is reachable without login, so push monitors (scripts reporting their own
  heartbeat) work. Every other path, including status pages and badges, needs an admin login.
- Docker container monitors need the Docker socket mounted (commented out in `docker-compose.yml`);
  that gives Kuma root-equivalent access to the server.
- Port 4180 is bound to `127.0.0.1` only, so there is no "Open on home network" link.
