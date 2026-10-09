# OpenCloud

Files, sharing and sync (web, desktop, Android, iOS). It runs from this folder's
`docker-compose.yml` and has its own address, `https://<OPENCLOUD_HOST>/`
(`opencloud.<tailnet>.ts.net`), as a Tailscale Service. Login goes through Authelia (OpenID
Connect); OpenCloud's own login service is turned off. Accounts are created automatically
on a user's first login.

| Piece | Where |
|---|---|
| Container, settings | `apps/opencloud/docker-compose.yml`, `.env` (from `.env.example`, not committed) |
| Role mapping (Authelia group → OpenCloud role) | `apps/opencloud/config/proxy.yaml` |
| Content Security Policy | `apps/opencloud/config/csp.yaml` |
| OIDC clients (web, Android, iOS, desktop) | `apps/opencloud/authelia-clients.yml`, appended to `gateway/authelia/config/configuration.yml` |
| Host name for Authelia | `OPENCLOUD_HOST` in `gateway/.env` |
| Landing page tile | `web/apps.json` (entry `opencloud`) |

Sources: Authelia's [openCloud integration guide](https://www.authelia.com/integration/openid-connect/clients/opencloud/)
(tested with openCloud 7.2.4 and Authelia 4.39) and the official
[opencloud-compose](https://github.com/opencloud-eu/opencloud-compose) repository. The image is
pinned to the stable `opencloudeu/opencloud:7.2.4` (the version Authelia tested).

## Who gets in

The roles come from Authelia groups ([config/proxy.yaml](config/proxy.yaml)):

| Authelia group | OpenCloud role |
|---|---|
| `opencloud-admins` | admin |
| `family` | user |

Someone in neither group can't log in to OpenCloud. Add `opencloud-admins` to your own entry in
`gateway/authelia/config/users_database.yml` (keep `family` too).

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `opencloud`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).

## 2. Register OpenCloud in Authelia

The clients from `authelia-clients.yml` are already in `gateway/authelia/config/configuration.yml`
(don't append them again). From the repository root:

```bash
cd gateway
grep -q '^OPENCLOUD_HOST=' .env || echo "OPENCLOUD_HOST=opencloud.$(grep '^SERVER_NAME=' .env | cut -d= -f2 | cut -d. -f2-)" >> .env
sudo docker compose up -d
sudo docker compose logs --tail=20 authelia      # should end with "Startup complete"
```

The clients are public (the apps can't keep a secret), so no client secret is needed; PKCE
protects the login instead.

## 3. Start OpenCloud

```bash
cd apps/opencloud
./scripts/setup.sh /srv/opencloud/config /mnt/data/opencloud
sudo docker compose logs -f opencloud
```

The two arguments are the config folder (OpenCloud's generated secrets) and the data folder
(users' files, on the data disk). Both must be absolute paths outside the repository. Leave them
out to be asked, with defaults. The script asks for the password of OpenCloud's built-in admin
account without showing it (empty = generate one), shows a summary and writes `.env` only after
you confirm. Then it creates the folders, checks that a container can reach Authelia and starts
OpenCloud. Running it again reuses `.env`; edit `.env` to change the values later.

Then publish it:

```bash
sudo tailscale serve --service=svc:opencloud --https=443 http://127.0.0.1:9200
sudo tailscale serve status
```

If the service shows "Pending approval" in the admin console, approve it once.

## 4. Test

1. `https://<OPENCLOUD_HOST>/` sends you to the gateway login page, then back to OpenCloud.
2. Your account was created on that first login; with `opencloud-admins`, "Admin settings" is in the user menu.
3. Desktop, Android, iOS: add the account with `https://<OPENCLOUD_HOST>`. The app finds the
   Authelia login itself (WebFinger) and opens it in a browser.

## Logout

There is no direct way to end OpenCloud's session from the landing page: Authelia 4.39 has no
OpenID Connect logout (RP-initiated, front- or back-channel), and the web app keeps its tokens in
the browser's storage for `<OPENCLOUD_HOST>`, out of the landing page's reach. So there is no
`logoutUrl` in `web/apps.json` for it.

Instead, the web app's session depends on the Authelia session:

- The web client (`opencloud`) gets no refresh token (no `offline_access`) and its access tokens
  last 1 minute (`lifespans.custom.opencloud_web` in `configuration.yml`).
- To renew, the web app asks Authelia in a hidden frame (`oidc-silent-redirect.html`). That only
  succeeds while the gateway login is active; afterwards it falls back to the login page.

**Shortcoming:** after the landing page's "Log Out", OpenCloud in an open browser tab keeps working
for up to about a minute (the token's remaining lifetime plus the proxy's 10-second userinfo cache).
An immediate logout would need Authelia to be asked on every request, which doesn't work here:
the token stays valid after logout, the Authelia cookie isn't sent to `<OPENCLOUD_HOST>`, and the
desktop/mobile apps carry no cookie at all. OpenCloud's own "Log out" ends it immediately.

The desktop, Android and iOS apps keep their refresh tokens and are not logged out by the landing
page (they don't share the browser's login).

Without "remember me", the web app also asks for login again when the Authelia session runs out.

## Backup

`OPENCLOUD_CONFIG_DIR` (contains `opencloud.yaml` with OpenCloud's generated secrets), `OPENCLOUD_DATA_DIR`
(files and metadata) and `.env`. Stop the container for a consistent copy.

## Notes and unverified items

- OpenCloud's web app exchanges the login code for tokens from the browser, so Authelia must send
  CORS headers: `identity_providers.oidc.cors` in `configuration.yml` (origins taken from the
  clients' redirect URIs). Without it, login hangs on "waiting to be redirected" with a CORS
  error on `/auth/api/oidc/token` in the browser console.
- The desktop and mobile apps request `offline_access`, so Authelia shows its consent page once per
  login there, even with `consent_mode: implicit` (Authelia requires explicit consent for refresh
  tokens). The web app no longer requests it, so it shouldn't show the consent page.
- Unverified: that the web app renews through the hidden frame when it has no refresh token, and
  returns to the login page cleanly when that fails. Test: log in, open OpenCloud, "Log Out" on the
  landing page, wait a minute, click around in OpenCloud; it should ask for login. If renewal
  breaks while logged in (logged out every minute), put `offline_access` back in
  `WEBFINGER_WEB_OIDC_CLIENT_SCOPES` and the `opencloud` client (scopes, `refresh_token` grant).

- Authelia's guide uses `two_factor`; here it is `one_factor` and `consent_mode: implicit`, matching
  Immich (Authelia 4.39 accepts this for public clients).
- `config/proxy.yaml` is mounted next to the generated `opencloud.yaml`, as Authelia's guide
  describes. The opencloud-compose repository instead puts the same mapping under `proxy:` in
  `opencloud.yaml`. If logins fail with "no roles in user claims", check the mapping is read.
- Port 9200 is bound to `127.0.0.1` only, so there is no "Open on home network" link.
- Basic auth for plain WebDAV clients is off (the default). The official apps use OpenID Connect.
