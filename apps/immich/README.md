# Immich

Photos and videos. Runs from this folder's `docker-compose.yaml` (Immich's official file;
container `immich_server`, port 2283). It has its own address, `https://<IMMICH_HOST>/`
(`immich.<tailnet>.ts.net`), as a Tailscale Service. Family members log in through Authelia
(OpenID Connect).

| Piece | Where |
|---|---|
| Containers, settings | `apps/immich/docker-compose.yaml`, `.env` (from `.env.example`, not committed) |
| Landing page tile + logout URL | `web/apps.json` (entry `immich`) |
| OIDC client | `gateway/authelia/config/configuration.yml` → `identity_providers.oidc.clients` |
| Client secret digest | `gateway/authelia/secrets/immich_client_digest` (not committed; `setup.sh` creates it) |
| Host name | `IMMICH_HOST` in `gateway/.env` (`setup.sh` adds it) |

`docker-compose.yaml` and `.env.example` are Immich's own files, unchanged apart from the
defaults in `.env.example`. On an Immich upgrade that needs a new compose file, replace
`docker-compose.yaml` with the release's file (re-add `extra_hosts` if you needed it, step 3).

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `immich`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).

## 2. Start Immich

```bash
cd apps/immich
./scripts/setup.sh /srv/data/photos/immich /home/immich/postgres
sudo docker compose logs -f immich-server
```

The two arguments are the photos and videos folder (`UPLOAD_LOCATION`, on the data disk) and the
database folder (`DB_DATA_LOCATION`, a local disk, ideally the SSD). Both must be absolute paths
outside the repository; leave them out to be asked. The script

1. writes `.env` (after showing a summary) with the server's timezone and a generated database
   password,
2. creates the client secret if Authelia has none yet: the digest goes into
   `gateway/authelia/secrets/immich_client_digest`; the plain secret is printed once at the end,
   for step 4, and stored nowhere else,
3. adds `IMMICH_HOST` to `gateway/.env` and recreates Authelia if either was new
   (this logs everyone out: sessions are kept in memory),
4. creates missing folders (existing ones are left as they are) and checks that a container can
   reach Authelia,
5. starts Immich and prints the values for step 4.

Running it again reuses `.env` and the digest. It refuses to run while Immich is running from
another folder (see "Moving an existing installation").

Then publish it:

```bash
sudo tailscale serve --service=svc:immich --https=443 http://127.0.0.1:2283
sudo tailscale serve status
```

This serves Immich at `https://<IMMICH_HOST>/` (port 443 outside, so no port in the address; 2283 inside).
If the service shows "Pending approval" in the admin console, approve it once.

## 3. Check that Immich can reach Authelia

```bash
curl -s https://<SERVER_NAME>/auth/.well-known/openid-configuration | head -c 120; echo
sudo docker exec immich_server node -e "fetch('https://<SERVER_NAME>/auth/.well-known/openid-configuration').then(r=>r.text()).then(t=>console.log(t.slice(0,120))).catch(e=>console.error(e.cause||e))"
```

Both should print JSON starting with `{"issuer":"https://<SERVER_NAME>/auth"`. If the second one
reports `ENOTFOUND`, add this to `immich-server` in `docker-compose.yaml` (address from
`tailscale ip -4`) and recreate it with `sudo docker compose up -d`:

```yaml
    extra_hosts:
      - "<SERVER_NAME>:100.x.y.z"
```

## 4. Immich OAuth settings

Administration → Settings → Authentication Settings → OAuth:

| Setting | Value |
|---|---|
| Enable | on |
| Issuer URL | `https://<SERVER_NAME>/auth/.well-known/openid-configuration` |
| Client ID | `immich` |
| Client Secret | the secret `setup.sh` printed (step 2) |
| Scope | `openid email profile` |
| Signing algorithm | `RS256` |
| Profile signing algorithm | `none` |
| Button text | e.g. "Log in with home account" |
| Auto register | off |
| Auto launch | off (turn on in step 5) |

Leave password login on until every account is linked; it is the way back in if something breaks.

## 5. Link each account

Each family member logs into Immich with their Immich password once, goes to Account Settings →
OAuth → Link, and logs in through the gateway's login page. After that, the "Log in with home
account" button works for them on the web and in the mobile app.

When everyone is linked, turn on Auto launch (Immich goes straight to the login page) and,
optionally, turn off password login. Guests still get Immich's own form: their tile links to
`/auth/login?autoLaunch=0`.

## Moving an existing installation

If Immich already runs from a folder outside this repository, move it without touching the data:

```bash
cd /path/to/old/immich
sudo docker compose down                     # stops Immich; photos and database stay on disk
cp .env <repo>/apps/immich/.env              # same folders, same database password
cd <repo>/apps/immich
chmod 600 .env
./scripts/setup.sh                           # reuses .env and the existing client secret
```

Keep `IMMICH_VERSION` in the copied `.env` at the version that was running; upgrade separately.
If the old `docker-compose.yml` had changes (e.g. `extra_hosts`, hardware acceleration), carry
them over to `docker-compose.yaml`. Immich's OAuth settings live in its database, so they stay.
Delete the old folder once Immich runs from here.

## Logout

There is no single logout between Authelia 4.39 and Immich. The landing page's "Log Out" ends the
Authelia session and then sends a blind `POST https://<IMMICH_HOST>/api/auth/logout` (the
`logoutUrl` in `web/apps.json`). Immich's own "Log out" button ends only Immich's session; with
Auto launch on, the user is logged straight back in while the Authelia session lasts.

## Notes

- Don't put `forward_auth` in front of Immich: it breaks the mobile app.
- Unverified: whether the browser sends Immich's cookie on the cross-host logout request, and
  whether Immich honours `?autoLaunch=0`. See [decisions.md](../../docs/decisions.md#open-items).
