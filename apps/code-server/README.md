# code-server

VS Code in the browser, for working on projects stored on the server. It runs from this folder's
`docker-compose.yml` and has its own address, `https://<CODE_SERVER_HOST>/`
(`code-server.<tailnet>.ts.net`), as a Tailscale Service. Only Authelia users in the group `admins`
get in.

Like Kuma, it sits behind [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/), which logs
in through Authelia (single sign-on). code-server's own password is turned off (`--auth none`), so
admins log in once. code-server itself is not published on any port.

```
https://<CODE_SERVER_HOST>/   tailscale serve --service=svc:code-server → 127.0.0.1:4183
  oauth2-proxy                no session → login at https://<SERVER_NAME>/auth
  └─ group admins  →          http://code-server:8080 (compose network only)
                                └─ /home/coder/project = CODE_SERVER_PROJECTS_DIR
```

| Piece | Where |
|---|---|
| Containers, settings | `apps/code-server/docker-compose.yml`, `.env` (from `.env.example`, not committed) |
| OIDC client (uses policy `admins_only`) | `apps/code-server/authelia-clients.yml`, already in `gateway/authelia/config/configuration.yml` |
| Client secret digest | `gateway/authelia/secrets/code-server_client_digest` (not committed; `setup.sh` creates it) |
| Host name for Authelia | `CODE_SERVER_HOST` in `gateway/.env` (`setup.sh` adds it) |
| Landing page tile + logout URL | `web/apps.json` (entry `code-server`) |

## Who gets in

The group `admins`, checked by Authelia (policy `admins_only`) and again by oauth2-proxy
(`OAUTH2_PROXY_ALLOWED_GROUPS`), as for Kuma. Everyone sees the tile on the landing page;
non-admins are refused when they open it.

code-server is a single-user editor: every admin works as the same user (`CODE_SERVER_UID_GID`, the
user who ran `setup.sh`) in the same projects folder, with the same settings.

## What it can reach

The terminal and the editor run inside the container. They see the projects folder and
code-server's own settings, nothing else of the server: no Docker socket, no other folders. The
container user has `sudo` inside the container (the image's default), which doesn't reach the server.
To give it more, add a volume in `docker-compose.yml`; every admin then gets that access too.

## Order after an update

`gateway/authelia/config/configuration.yml` now refers to `/secrets/code-server_client_digest` and
`gateway/docker-compose.yml` needs `CODE_SERVER_HOST` in `gateway/.env`. Until both exist, `docker
compose` in `gateway/` refuses to run and Authelia won't start. Run `setup.sh` (step 2) **before**
restarting the gateway.

Vaultwarden and Jellyfin were added in the same update and need the same. Run all three
`setup.sh` scripts (any order). Authelia keeps running with its old configuration until the last
one, which restarts it; the earlier ones print a note saying what is still missing.

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `code-server`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).

## 2. Start code-server

```bash
cd apps/code-server
./scripts/setup.sh /srv/data/code-server /home/<you>/projects
sudo docker compose logs -f
```

The arguments are code-server's data folder (settings, extensions) and the projects folder it
opens. Both must be absolute paths outside the repository; leave them out to be asked. The script

1. writes `.env` (after showing a summary) with your user and group, and generates oauth2-proxy's
   cookie secret,
2. generates the client secret: the plain one goes into `.env` (oauth2-proxy needs it), the digest
   into `gateway/authelia/secrets/code-server_client_digest`,
3. adds `CODE_SERVER_HOST` to `gateway/.env` and recreates Authelia if either was new and nothing
   else is missing (this logs everyone out: sessions are kept in memory),
4. creates the data folders (owned by you) and the projects folder if it doesn't exist yet
   (an existing one is left as it is), and checks that a container can reach Authelia,
5. starts code-server and oauth2-proxy.

Running it again reuses `.env` and the digest.

## 3. Publish it

```bash
sudo tailscale serve --service=svc:code-server --https=443 http://127.0.0.1:4183
sudo tailscale serve status
```

If the service shows "Pending approval" in the admin console, approve it once.

## 4. Test

1. Admin: `https://<CODE_SERVER_HOST>/` opens VS Code after the gateway login (or straight away when
   already logged in on the landing page), with the projects folder open.
2. Open a terminal (Terminal → New Terminal) and run `ls`: it shows the projects folder. If the
   editor stays blank or the terminal doesn't connect, see the websocket note below.
3. A family member without `admins`: Authelia refuses the login.

## Logout

As for Kuma: the landing page's "Log Out" ends the Authelia session and then sends a blind
`POST https://<CODE_SERVER_HOST>/oauth2/sign_out` (the `logoutUrl` in `web/apps.json`), which
clears oauth2-proxy's cookie. code-server has no session of its own (login off). oauth2-proxy's
session lasts up to 24 hours (`OAUTH2_PROXY_COOKIE_EXPIRE`) if you don't log out. An open tab
keeps its websocket until it reloads.

## Backup

The projects folder (your work; ideally also in git) and `.env`. `CODE_SERVER_DATA_DIR` only holds
settings and extensions, which can be set up again. The digest in `gateway/authelia/secrets/` is
backed up with the gateway; if it is lost, delete `CODE_SERVER_CLIENT_SECRET` from `.env` and run
`setup.sh` again.

## Notes and unverified items

- code-server checks that a websocket's `Origin` matches the `Host` header. Both tailscale serve and
  oauth2-proxy pass the original host on, and `--trusted-origins=<CODE_SERVER_HOST>` allows it
  explicitly as well. Not yet tested on the server: if the browser console shows websocket errors,
  check `sudo docker compose logs code-server` for "origin" messages.
- With its login off, code-server trusts every request that reaches port 8080. Only oauth2-proxy can
  reach it from outside the server, but the container's address is reachable from the server itself,
  so a local user on the server could use it. Same trade-off as Kuma.
- Extensions come from Open VSX (code-server's default), not Microsoft's marketplace; some
  Microsoft extensions are missing there.
- Port 4183 is bound to `127.0.0.1` only, so there is no "Open on home network" link.
