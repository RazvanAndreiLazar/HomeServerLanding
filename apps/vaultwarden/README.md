# Vaultwarden

Password manager for the family: a Bitwarden-compatible server, used with the official Bitwarden
apps, browser extensions and its web vault. It runs from this folder's `docker-compose.yml` and has
its own address, `https://<VAULTWARDEN_HOST>/` (`vaultwarden.<tailnet>.ts.net`), as a Tailscale
Service.

Family members can log in through Authelia (OpenID Connect, Vaultwarden's built-in SSO) or with
their email and master password. Either way, the **master password** is still needed: it encrypts
the vault on the device, and neither Authelia nor the server knows it. SSO replaces the email step,
not the master password.

```
https://<VAULTWARDEN_HOST>/   tailscale serve --service=svc:vaultwarden → 127.0.0.1:8222 → vaultwarden:80
  "Use single sign-on"        → login at https://<SERVER_NAME>/auth → back to /identity/connect/oidc-signin
  email + master password     → Vaultwarden's own login (apps, fallback)
```

| Piece | Where |
|---|---|
| Container, settings | `apps/vaultwarden/docker-compose.yml`, `.env` (from `.env.example`, not committed) |
| OIDC client | `apps/vaultwarden/authelia-clients.yml`, already in `gateway/authelia/config/configuration.yml` |
| Client secret digest | `gateway/authelia/secrets/vaultwarden_client_digest` (not committed; `setup.sh` creates it) |
| Host name for Authelia | `VAULTWARDEN_HOST` in `gateway/.env` (`setup.sh` adds it) |
| Landing page tile | `web/apps.json` (entry `vaultwarden`) |

## Who gets in

- **New accounts** are created only through the Authelia login (`SSO_SIGNUPS_ALLOWED`); the
  "Create account" form is off (`SIGNUPS_ALLOWED=false`). So every family member with an Authelia
  account can create a vault, and nobody else can.
- **Existing accounts** (e.g. created before SSO was on) are linked on their first SSO login when the
  email matches the one in `gateway/authelia/config/users_database.yml` (`SSO_SIGNUPS_MATCH_EMAIL`).
  Vaultwarden only links when Authelia reports the email as verified.
- Each vault belongs to its user alone. To share passwords, create an organization in the web
  vault (e.g. "Family") and invite members by email; without an email server they appear in the
  organization at once and an owner confirms them (Members → Confirm).

## Order after an update

`gateway/authelia/config/configuration.yml` now refers to `/secrets/vaultwarden_client_digest` and
`gateway/docker-compose.yml` needs `VAULTWARDEN_HOST` in `gateway/.env`. Until both exist, `docker
compose` in `gateway/` refuses to run and Authelia won't start. Run `setup.sh` (step 2) **before**
restarting the gateway.

code-server and Jellyfin were added in the same update and need the same. Run all three `setup.sh`
scripts (any order). Authelia keeps running with its old configuration until the last one, which
restarts it; the earlier ones print a note saying what is still missing.

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `vaultwarden`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).

## 2. Start Vaultwarden

```bash
cd apps/vaultwarden
./scripts/setup.sh /srv/data/vaultwarden
sudo docker compose logs -f
```

The argument is Vaultwarden's data folder (database, attachments, keys), an absolute path outside
the repository; leave it out to be asked. The script

1. writes `.env` (after showing a summary),
2. generates the client secret: the plain one goes into `.env` (Vaultwarden needs it), the digest
   into `gateway/authelia/secrets/vaultwarden_client_digest`,
3. adds `VAULTWARDEN_HOST` to `gateway/.env` and recreates Authelia if either was new and nothing
   else is missing (this logs everyone out: sessions are kept in memory),
4. creates the data folder and checks that a container can reach Authelia,
5. starts Vaultwarden.

Running it again reuses `.env` and the digest.

## 3. Publish it

```bash
sudo tailscale serve --service=svc:vaultwarden --https=443 http://127.0.0.1:8222
sudo tailscale serve status
```

If the service shows "Pending approval" in the admin console, approve it once.

## 4. Create the accounts

Each family member, once, in a browser:

1. Open `https://<VAULTWARDEN_HOST>/`, enter their email (the one in Authelia's users file) and
   choose **Use single sign-on**.
2. Log in on the gateway's login page (or go straight on when already logged in).
3. Back in Vaultwarden, set a **master password**. Choose a long passphrase and write it down
   somewhere safe: if it is forgotten, the vault can't be opened by anyone, the admin included.

## 5. Apps and browser extensions

In the Bitwarden app or extension, before logging in: the region / server selector → **Self-hosted**
→ Server URL `https://<VAULTWARDEN_HOST>` → Save. Then log in with email and master password (this
always works), or with **Use single sign-on**.

Devices only reach the server while Tailscale is on. Without it, the apps still show and fill the
last synced passwords, but changes sync only once Tailscale is back.

## 6. Test

1. `https://<VAULTWARDEN_HOST>/` → email → Use single sign-on → gateway login → Vaultwarden asks for
   the master password (new account: sets one) and opens the vault.
2. The same account logs in with email + master password in an app.
3. "Create account" on the login page is refused.

## Admin page

Off (no `ADMIN_TOKEN`). It is only needed for things like deleting a user or setting up an email
server. To turn it on for a while:

```bash
sudo docker compose exec vaultwarden /vaultwarden hash      # asks for a password, prints $argon2id$...
```

Add `ADMIN_TOKEN: '<the $argon2id$... string with every $ doubled as $$>'` to `environment` in
`docker-compose.yml`, `sudo docker compose up -d`, open `https://<VAULTWARDEN_HOST>/admin` and log in
with the password. Remove the line again afterwards. (Settings saved on the admin page go to
`config.json` in the data folder and override the compose file.)

## Logout

There is no `logoutUrl` in `web/apps.json`: the web vault keeps its tokens in the browser's storage
for `<VAULTWARDEN_HOST>`, out of the landing page's reach, and Authelia 4.39 has no OpenID Connect
logout. The landing page's "Log Out" doesn't end a Vaultwarden session; Vaultwarden's own "Log out"
or "Lock" does. The vault locks itself after the timeout set in each app (Settings → Vault timeout),
and unlocking always needs the master password.

## Backup

**The most important backup on the server**: `VAULTWARDEN_DATA_DIR` (`db.sqlite3*`, `attachments/`,
`sends/`, `rsa_key*`) and `.env`. Stop the container for a consistent copy
(`sudo docker compose stop`), or copy the database while it runs with
`sudo sqlite3 <VAULTWARDEN_DATA_DIR>/db.sqlite3 ".backup '/path/to/backup.sqlite3'"`. The vaults are
encrypted with each user's master password, but keep the backup encrypted too. The apps' offline
copy is not a backup. The digest in `gateway/authelia/secrets/` is backed up with the gateway; if it
is lost, delete `VAULTWARDEN_CLIENT_SECRET` from `.env` and run `setup.sh` again.

## Notes and unverified items

- SSO came to Vaultwarden in 1.35.0. Checked against the 1.37.4 source: SSO signups are allowed
  independently of `SIGNUPS_ALLOWED`; existing accounts are linked by email only when the provider
  says the email is verified. Not yet tested on the server: that Authelia's userinfo includes
  `email_verified: true`. If the login fails with "Email verification status is unknown", check
  `sudo docker compose logs vaultwarden`.
- `SSO_AUTH_ONLY_NOT_SESSION=true`: Authelia is asked only at login. Vaultwarden then keeps its own
  session (2-hour access token, refreshed for up to 7 days of inactivity), so the apps stay logged
  in without `offline_access` (which would bring Authelia's consent page).
- SSO in the Bitwarden mobile apps needs app version 2026.1.0 or newer and is unverified here. The
  app may ask for an "SSO identifier"; Vaultwarden has only one SSO setup and fills in its own.
  Email + master password always works in the apps.
- Authelia's Vaultwarden guide maps groups to roles (`SSO_ROLES_*`). Those settings belong to the
  OIDCWarden fork and are not in Vaultwarden 1.37.4, so they are left out.
- Vaultwarden needs HTTPS for the web vault (the browser's crypto API), so it is bound to
  `127.0.0.1` only and has no "Open on home network" link.
- No email server: no invitation emails, no "new device" notices, no email two-factor. Two-factor
  with an authenticator app works (web vault → Settings → Security → Two-step login).
