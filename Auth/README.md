# Home server gateway

Login and entry point for the home server. Family members log in once and reach the landing
page, protected apps and Immich with the same account. Guests see the landing page without
logging in. Everything is reachable only inside the tailnet.

```
device (in tailnet)
  │
  ├─ https://<SERVER_NAME>/          tailscale serve → Caddy :8080
  │     /            landing page (public)
  │     /config.json machine-specific values for the landing page
  │     /auth/*      Authelia: login, logout, single sign-on provider
  │     /whoami/*    test app, only after login (Caddy asks Authelia first)
  │
  └─ https://<IMMICH_HOST>/          Tailscale Service svc:immich → Immich :2283
                                     login via Authelia (OpenID Connect)
```

| Component | Role |
|---|---|
| Tailscale Serve | HTTPS with a valid certificate, no open ports on the router |
| Caddy | Routes requests and asks Authelia before passing any protected request on |
| Authelia | Users, passwords, sessions ("remember me"), single sign-on for apps |
| Landing page | Static page in `../landing`, lists the apps |

## Repository layout

```
Auth/
  .gitignore
  landing/
    index.html                          the landing page (everything in this folder is public)
  gateway/
    README.md                           this file
    .env.example                        template for .env
    docker-compose.yml
    caddy/Caddyfile
    authelia/config/configuration.yml
    authelia/config/users_database.example.yml
```

Not committed (see `../.gitignore`), created during setup and kept only on the server:

| File | Contents |
|---|---|
| `.env` | Server name, home IP, Immich name |
| `authelia/secrets/*` | Authelia's keys |
| `authelia/config/users_database.yml` | Users and password hashes |
| `authelia/config/db.sqlite3`, `notification.txt` | Authelia's own data |

## Prerequisites

- Debian server in the tailnet, with Docker and the Compose plugin, `jq` and `openssl`.
- Tailscale 1.86 or newer on the server; clients on 1.94 or newer see Tailscale Services
  automatically (older Linux clients: `sudo tailscale set --accept-routes`).
- In the Tailscale admin console, under DNS: MagicDNS and HTTPS Certificates turned on.
- Immich running from its own `docker-compose.yml` (container `immich_server`), listening on port 2283.

All commands below run on the server, from `Auth/gateway` unless stated otherwise.

## 1. Prepare Tailscale for named services

Immich gets its own address (`immich.<tailnet>.ts.net`) as a Tailscale Service. That needs a tagged server.

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
   for your devices to `"dst": ["svc:immich"], "ip": ["443"]`.

2. Admin console → Machines → the server → "…" → Edit ACL tags → add `tag:server`.
   Check that it is still enabled as an exit node.

3. Admin console → Services → Advertise → Define a Service:
   name `immich`, endpoint `tcp:443`, tag `tag:server-svc`.

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
sudo mkdir -p authelia/secrets
for s in jwt session storage oidc_hmac; do
  openssl rand -hex 64 | sudo tee authelia/secrets/$s >/dev/null
done
sudo openssl genrsa -out authelia/secrets/oidc_jwks.pem 2048
```

| Secret | Used for |
|---|---|
| `session` | Encrypts session data |
| `storage` | Encrypts sensitive fields in Authelia's database |
| `jwt` | Signs password-reset links (required even though reset is disabled) |
| `oidc_hmac`, `oidc_jwks.pem` | Sign the single sign-on tokens given to apps |

Then the shared secret between Authelia and Immich:

```bash
sudo docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 \
  --variant sha512 --random --random.length 72 --random.charset rfc3986
```

It prints a `Random Password` and a `Digest`. Keep the password for step 8 (it goes into Immich;
no need to store it anywhere else). Save the digest, keeping the single quotes:

```bash
printf '%s' '$pbkdf2-sha512$...whole digest...' | sudo tee authelia/secrets/immich_client_digest >/dev/null
sudo chmod 700 authelia/secrets && sudo chmod 600 authelia/secrets/*
```

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

## 6. Publish the gateway and Immich in the tailnet

```bash
sudo tailscale serve --bg http://127.0.0.1:8080
sudo tailscale serve --service=svc:immich --https=443 http://127.0.0.1:2283
sudo tailscale serve status
```

The first command serves Caddy at `https://<SERVER_NAME>/`. The second serves Immich at
`https://<IMMICH_HOST>/` (outside port 443, so no port in the address; inside, Immich's 2283).
If the service shows "Pending approval" in the admin console, approve it once.

## 7. Test the gateway

1. `https://<SERVER_NAME>/` shows the landing page without logging in.
2. `https://<SERVER_NAME>/whoami` redirects to the login page.
3. Log in with "Remember me" ticked. You return to `/whoami`, which lists `Remote-User: <your user>`.
4. Close and reopen the browser: `/whoami` still opens without logging in.
5. `https://<SERVER_NAME>/auth/logout` logs out; `/whoami` asks for login again.

## 8. Connect Immich to Authelia (single sign-on)

Check that the Immich server can reach Authelia from inside its container:

```bash
curl -s https://<SERVER_NAME>/auth/.well-known/openid-configuration | head -c 120; echo
sudo docker exec immich_server node -e "fetch('https://<SERVER_NAME>/auth/.well-known/openid-configuration').then(r=>r.text()).then(t=>console.log(t.slice(0,120))).catch(e=>console.error(e.cause||e))"
```

Both should print JSON starting with `{"issuer":"https://<SERVER_NAME>/auth"`. If the second one
reports `ENOTFOUND`, add this to `immich-server` in Immich's `docker-compose.yml` (address from
`tailscale ip -4`) and recreate it with `docker compose up -d`:

```yaml
    extra_hosts:
      - "<SERVER_NAME>:100.x.y.z"
```

In Immich: Administration → Settings → Authentication Settings → OAuth:

| Setting | Value |
|---|---|
| Enable | on |
| Issuer URL | `https://<SERVER_NAME>/auth/.well-known/openid-configuration` |
| Client ID | `immich` |
| Client Secret | the `Random Password` from step 3 |
| Scope | `openid email profile` |
| Signing algorithm | `RS256` |
| Profile signing algorithm | `none` |
| Button text | e.g. "Log in with home account" |
| Auto register | off |
| Auto launch | off |

Leave password login on until every account is linked; it is the way back in if something breaks.

## 9. Link each Immich account

Each family member logs into Immich with their Immich password once, goes to Account Settings →
OAuth → Link, and logs in through Authelia. After that, the "Log in with home account" button
works for them on the web and in the mobile app.

When everyone is linked, you can turn on Auto launch (Immich goes straight to Authelia) and,
optionally, turn off password login.

## 10. Remove the test app

Delete the `whoami` service from `docker-compose.yml`, its `handle /whoami*` block from the
Caddyfile and its rule from `configuration.yml`, then:

```bash
sudo docker compose up -d --remove-orphans
```

Keep the `access_control` section: its `default_policy: deny` blocks anything without a rule.

## Day-to-day

**Add a family member.** Generate a hash (step 4), add their block to `users_database.yml`.
Authelia picks it up without a restart. They then link their Immich account (step 9).

**Change a password.** Replace the hash in `users_database.yml`.

**Add an app to the landing page.** Add an entry to `appList` in `../landing/index.html`.
No restart needed.

**Protect a new app behind the login** (apps on the main address, e.g. `/files`):
add a `handle /files*` block to the Caddyfile modelled on the old `whoami` block, add a matching
rule under `access_control` in `configuration.yml`, then `sudo docker compose up -d` and
`sudo docker compose restart caddy`.

**Give a new app its own name and single sign-on:** define a Tailscale Service for it (step 1.3
and step 6), add a client for it under `identity_providers.oidc.clients` (with its own
digest file, step 3), and configure the app's OpenID Connect settings like Immich in step 8.

**Upgrade Authelia.** The image is pinned (`4.39`). Change the tag deliberately, read the release
notes, then `sudo docker compose pull && sudo docker compose up -d` and repeat the tests in step 7.

## Backup

Back up `Auth/gateway` including its ignored files: `.env`, `authelia/secrets/*`,
`authelia/config/users_database.yml` and `authelia/config/db.sqlite3`. Keep the backup encrypted,
since it contains the keys and password hashes.

## Known limitations

- Sessions live in Authelia's memory. Restarting Authelia logs everyone out, including
  "remember me" sessions.
- Immich keeps its own session: logging out of Authelia does not log you out of Immich.
- There is no password reset by email; passwords are changed in `users_database.yml`.
