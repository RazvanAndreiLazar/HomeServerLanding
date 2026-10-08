# Setup

Linear setup guide for the gateway (Caddy + Authelia + web pages). Apps are set up afterwards,
each from its own README under [`apps/`](../apps/).

All commands run on the server, from `gateway/` unless stated otherwise.

## Prerequisites

- Debian server in the tailnet, with Docker and the Compose plugin, `jq` and `openssl`.
- Tailscale 1.86 or newer on the server; clients on 1.94 or newer see Tailscale Services
  automatically (older Linux clients: `sudo tailscale set --accept-routes`).
- In the Tailscale admin console, under DNS: MagicDNS and HTTPS Certificates turned on.

## 1. Prepare Tailscale for named services

Apps with their own address (`<app>.<tailnet>.ts.net`, e.g. Immich) are Tailscale Services.
That needs a tagged server. Do this once, even if you add apps later.

1. Admin console → Access controls. Merge these keys into the existing policy (don't replace it):

   ```json
   "tagOwners": {
     "tag:server": ["autogroup:admin"]
   },
   "autoApprovers": {
     "services": {
       "tag:server-svc": ["tag:server"]
     }
   }
   ```

   With the default "allow all" policy nothing else is needed. With your own rules, add a grant
   per service for your devices, e.g. `"dst": ["svc:immich"], "ip": ["443"]`.

2. Admin console → Machines → the server → "…" → Edit ACL tags → add `tag:server`.
   Check that it is still enabled as an exit node.

## 2. Create .env

```bash
cp .env.example .env
NAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
sed -i "s/^SERVER_NAME=.*/SERVER_NAME=$NAME/" .env
nano .env        # set LAN_IP, and IMMICH_HOST=immich.<tailnet>.ts.net (same tailnet part as SERVER_NAME)
chmod 600 .env
```

## 3. Generate the secrets

Authelia needs random keys it uses internally. Generate them here on the server so they never
leave it, and include them in the server backup.

```bash
./scripts/create_secrets.sh
```

| Secret | Used for |
|---|---|
| `session` | Encrypts session data |
| `storage` | Encrypts sensitive fields in Authelia's database |
| `jwt` | Signs password-reset links (required even though reset is disabled) |
| `oidc_hmac`, `oidc_jwks.pem` | Sign the single sign-on tokens given to apps |
| `<app>_client_digest` | One per single sign-on app; created in that app's README |

The script keeps files that already exist.

## 4. Create the users

```bash
cp authelia/config/users_database.example.yml authelia/config/users_database.yml
sudo docker run --rm -it authelia/authelia:4.39 authelia crypto hash generate argon2
```

For each family member, add a block to `users_database.yml` with the `$argon2id$...` hash the
command prints, and put them in the `family` group. Then:

```bash
chmod 600 authelia/config/users_database.yml
```

## 5. Start the gateway

```bash
sudo docker compose config > /dev/null && echo "config ok"
sudo docker compose up -d
sudo docker compose logs --tail=30 authelia      # should end with "Startup complete"
```

Authelia refuses to start while `configuration.yml` lists an OIDC client whose digest file is
missing. On a fresh install, set up each app (`apps/<app>/README.md`) before this step, or
comment out its client block until then.

## 6. Publish the gateway in the tailnet

```bash
sudo tailscale serve --bg http://127.0.0.1:8080
sudo tailscale serve status
```

This serves Caddy at `https://<SERVER_NAME>/`.

## 7. Test the gateway

1. `https://<SERVER_NAME>/` shows the landing page without logging in; the button says "Log In".
2. "Log In" opens the login page (same style as the landing page, address `/auth/`).
3. A wrong password shows an error.
4. Log in with "Remember me" ticked. You return to the landing page, greeted by name.
5. Close and reopen the browser: still logged in.
6. "Log Out" returns you to the guest view.
7. `https://<SERVER_NAME>/auth/?portal=1` shows Authelia's own portal (fallback) with the house logo.

## 8. Set up the apps

Follow each app's README: [Immich](../apps/immich/README.md).
To add a new one: [adding-an-app.md](adding-an-app.md).

## Migrating from the old `Auth/` layout

The repository used to keep everything under `Auth/`. On a server that ran it from there:

```bash
cd <repo>/Auth && sudo docker compose down
cd <repo> && git pull
# git moves the tracked files; the ignored ones stay behind in Auth/
sudo mv Auth/.env gateway/.env
sudo mv Auth/authelia/secrets gateway/authelia/secrets
sudo mv Auth/authelia/config/users_database.yml Auth/authelia/config/db.sqlite3 \
        Auth/authelia/config/notification.txt gateway/authelia/config/
sudo find Auth -depth -type d -empty -delete
cd gateway && sudo docker compose up -d
```

`tailscale serve` needs no change (still port 8080). The compose project is now called `gateway`,
so containers and the `caddy_data` volume get new names. That's harmless: Caddy issues no
certificates here. Everyone is logged out (sessions live in memory).

## Day-to-day

**Add a family member.** Generate a hash (step 4), add their block to `users_database.yml`.
Authelia picks it up without a restart. Then link their app accounts (see each app's README).

**Change a password.** Replace the hash in `users_database.yml`.

**Add or change an app.** See [adding-an-app.md](adding-an-app.md).

**Change the look.** All pages share `web/assets/theme.css`. Authelia's fallback portal uses
`gateway/authelia/assets/logo.png` and `favicon.ico`; restart Authelia after changing them.

**Upgrade Authelia.** The image is pinned (`4.39`). Change the tag deliberately, read the release
notes, then `sudo docker compose pull && sudo docker compose up -d` and repeat the tests in step 7.
The web pages use Authelia's internal API (`/auth/api/state`, `/auth/api/user/info`,
`/auth/api/firstfactor`, `/auth/api/logout`), which has no version guarantee. If login breaks,
compare with what the fallback portal (`/auth/?portal=1`) sends in the browser's network tab,
and adjust `FORWARDED_PARAMS` in `web/assets/login.js`.

## Backup

Back up `gateway/` including its ignored files: `.env`, `authelia/secrets/*`,
`authelia/config/users_database.yml` and `authelia/config/db.sqlite3`. Keep the backup encrypted,
since it contains the keys and password hashes.

## Known limitations

- Sessions live in Authelia's memory. Restarting Authelia logs everyone out, including
  "remember me" sessions.
- Apps keep their own sessions. The landing page's "Log Out" ends them via each app's
  `logoutUrl` (in `web/apps.json`); logging out anywhere else ends only that one session.
- There is no password reset by email; passwords are changed in `users_database.yml`.
- The login page handles password-only login (`one_factor`). Two-factor or consent screens
  would fall back to Authelia's own pages.
