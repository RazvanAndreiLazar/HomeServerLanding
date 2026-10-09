# Beszel

Server resources: CPU, memory, disks, network, temperatures and containers, with history and
alerts. It runs from this folder's `docker-compose.yml` (hub + agent for this server) and has its
own address, `https://<BESZEL_HOST>/` (`beszel.<tailnet>.ts.net`), as a Tailscale Service. Only
Authelia users in the group `admins` get in. Uptime Kuma ([apps/kuma](../kuma/README.md)) answers
"is it up?"; Beszel answers "how is the machine doing?".

Like Kuma, it sits behind [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/), which logs
in through Authelia (single sign-on). Beszel can't turn its own login off, but it trusts a header:
oauth2-proxy passes the user's email as `X-Forwarded-Email`, and Beszel logs in the Beszel user
with that email (`TRUSTED_AUTH_HEADER`).

```
https://<BESZEL_HOST>/  tailscale serve --service=svc:beszel → 127.0.0.1:4181
  oauth2-proxy (172.31.250.2)  no session → login at https://<SERVER_NAME>/auth
  └─ group admins → http://beszel:8090 + X-Forwarded-Email (trusted only from 172.31.250.2)
beszel (hub) ── SSH over the Unix socket in volume beszel_socket ──► beszel-agent (host network)
```

| Piece | Where |
|---|---|
| Containers, settings | `apps/beszel/docker-compose.yml`, `.env` (from `.env.example`, not committed) |
| OIDC client (uses policy `admins_only`) | `apps/beszel/authelia-clients.yml`, already in `gateway/authelia/config/configuration.yml` |
| Client secret digest | `gateway/authelia/secrets/beszel_client_digest` (not committed; `setup.sh` creates it) |
| Host name for Authelia | `BESZEL_HOST` in `gateway/.env` (`setup.sh` adds it) |
| Landing page tile + logout URL | `web/apps.json` (entry `beszel`) |

## Who gets in

Two conditions:

1. **Group `admins`**, checked by Authelia (policy `admins_only`) and again by oauth2-proxy
   (`OAUTH2_PROXY_ALLOWED_GROUPS`), as for Kuma.
2. **A Beszel user with the same email** as in Authelia's users file. The trusted header only logs
   in existing users; it never creates them. `setup.sh` creates the first one from
   `BESZEL_ADMIN_EMAIL`.

   An admin without a Beszel user passes the login and gets Beszel's login page, which has no way
   in (password login is off). To add one: Beszel's admin UI, `https://<BESZEL_HOST>/_/`, log in
   as `BESZEL_ADMIN_EMAIL` with `BESZEL_ADMIN_PASSWORD` from `.env` → Collections → `users` →
   New record: their Authelia email, any random password, "verified" on.

## Order after an update

`gateway/authelia/config/configuration.yml` now refers to `/secrets/beszel_client_digest` and
`gateway/docker-compose.yml` needs `BESZEL_HOST` in `gateway/.env`. Until both exist, `docker compose`
in `gateway/` refuses to run and Authelia won't start. Run `setup.sh` (step 2) **before** restarting
the gateway; it creates both and restarts Authelia itself.

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `beszel`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).

## 2. Start Beszel

```bash
cd apps/beszel
./scripts/setup.sh /srv/data/beszel
sudo docker compose logs -f
```

The argument is Beszel's data folder (database and the hub's SSH key), an absolute path outside the
repository; leave it out to be asked. The script also asks for your email (as in Authelia's users
file). Then it

1. writes `.env` (after showing a summary), generating the admin password and oauth2-proxy's
   cookie secret,
2. generates the client secret: the plain one into `.env`, the digest into
   `gateway/authelia/secrets/beszel_client_digest`,
3. adds `BESZEL_HOST` to `gateway/.env` and recreates Authelia if either was new
   (this logs everyone out: sessions are kept in memory),
4. creates the data folder and checks that a container can reach Authelia,
5. starts the hub, which creates its SSH key (`id_ed25519` in the data folder), writes the public
   key into `BESZEL_AGENT_KEY` (the agent only accepts that key), and starts everything.

Running it again reuses `.env`, the digest and the key.

## 3. Publish it

```bash
sudo tailscale serve --service=svc:beszel --https=443 http://127.0.0.1:4181
sudo tailscale serve status
```

If the service shows "Pending approval" in the admin console, approve it once.

## 4. Add this server

Open `https://<BESZEL_HOST>/` (you are logged in as yourself) → Add System:

| Field | Value |
|---|---|
| Name | anything, e.g. the server's name |
| Host / IP | `/beszel_socket/beszel.sock` |

Ignore the key and token shown in the dialog; the agent already has the key. The system turns
green and shows data within a minute.

Extra disks (e.g. the data disk): mount a folder from each under `/extra-filesystems/` in the
agent (example in `docker-compose.yml`), then `sudo docker compose up -d`.

## 5. Test

1. Admin: `https://<BESZEL_HOST>/` opens Beszel after the gateway login, logged in as yourself.
2. A family member without `admins`: Authelia refuses the login.
3. Landing page "Log Out", then open Beszel: it asks for login.
4. The trusted header only works through oauth2-proxy. On the server:

   ```bash
   ip=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(sudo docker compose ps -q beszel)")
   curl -s -X POST -H "X-Forwarded-Email: <your email>" "http://$ip:8090/api/collections/users/auth-refresh"
   ```

   should answer with an error (401/403), not a token.

## Logout

Every request goes through oauth2-proxy, so the landing page's "Log Out" ends Beszel at once: it
ends the Authelia session and then sends a blind `POST https://<BESZEL_HOST>/oauth2/sign_out`
(the `logoutUrl` in `web/apps.json`), as for Kuma. Beszel's own token in the browser stays, but
it can't be used without passing oauth2-proxy. oauth2-proxy's session lasts up to 24 hours
(`OAUTH2_PROXY_COOKIE_EXPIRE`) if you don't log out.

## Backup

`BESZEL_DATA_DIR` (database and the hub's SSH key) and `.env`. Stop the containers for a
consistent copy (`sudo docker compose stop`). If the key is lost, the hub makes a new one: clear
`BESZEL_AGENT_KEY` in `.env` and run `setup.sh` again.

## Adding another machine later

Not set up. An agent on another tailnet machine either listens on a port that the hub connects to
(SSH, port 45876; `KEY` = the same public key), or connects to the hub itself over WebSocket
(`HUB_URL` + `TOKEN`). The second way goes through oauth2-proxy and needs a login bypass for the
agent's path (`OAUTH2_PROXY_SKIP_AUTH_ROUTES`), so the first is simpler here.

## Notes

- The fixed network `172.31.250.0/29` exists so `TRUSTED_PROXY_IPS` can name oauth2-proxy alone:
  the hub's container address is reachable from the server itself, so without it any local user
  could log in by sending the header. If the subnet clashes with another Docker network, change
  the subnet, oauth2-proxy's `ipv4_address` and `TRUSTED_PROXY_IPS` together.
- `USER_EMAIL`/`USER_PASSWORD` only act on the very first start (empty data folder). Changing
  them later does nothing; use the admin UI.
- The agent mounts the Docker socket read-only for container stats; that is still root-equivalent
  access to the server.
- Port 4181 is bound to `127.0.0.1` only, so there is no "Open on home network" link.
- Checked against the Beszel 0.21.0 source: the trusted header looks up an existing user by email
  and is ignored from other addresses when `TRUSTED_PROXY_IPS` is set; the hub key is
  `/beszel_data/id_ed25519`, created at start. Not yet tested on the server.
