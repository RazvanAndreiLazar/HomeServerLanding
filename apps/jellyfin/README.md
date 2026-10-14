# Jellyfin

Films, series and music, streamed to browsers, phones and TVs. It runs from this folder's
`docker-compose.yml` and has its own address, `https://<JELLYFIN_HOST>/` (`jellyfin.<tailnet>.ts.net`),
as a Tailscale Service. Devices on the home network (e.g. a TV that isn't in the tailnet) use
`http://<LAN_IP>:8096` directly.

Jellyfin has no OpenID Connect login of its own. The community
[SSO plugin](https://github.com/9p4/jellyfin-plugin-sso) adds one: a "Log in with home account"
button on Jellyfin's login page that logs in through Authelia. The TV and phone apps can't use it;
they log in with Quick Connect (a code confirmed from a logged-in browser) instead.

```
https://<JELLYFIN_HOST>/   tailscale serve --service=svc:jellyfin → 127.0.0.1:8096 → jellyfin:8096
  login button             /sso/OID/start/authelia → login at https://<SERVER_NAME>/auth
                           → back to /sso/OID/redirect/authelia → Jellyfin session
http://<LAN_IP>:8096       home network: Quick Connect or Jellyfin password (no SSO)
```

| Piece | Where |
|---|---|
| Container, settings | `apps/jellyfin/docker-compose.yml`, `.env` (from `.env.example`, not committed) |
| SSO plugin settings | in Jellyfin (Dashboard → Plugins → SSO-Auth), stored in `<JELLYFIN_CONFIG_DIR>/plugins/configurations/SSO-Auth.xml` |
| OIDC client | `apps/jellyfin/authelia-clients.yml`, already in `gateway/authelia/config/configuration.yml` |
| Client secret digest | `gateway/authelia/secrets/jellyfin_client_digest` (not committed; `setup.sh` creates it) |
| Host name for Authelia | `JELLYFIN_HOST` in `gateway/.env` (`setup.sh` adds it) |
| Landing page tile | `web/apps.json` (entry `jellyfin`) |

Sources: Authelia's [Jellyfin integration guide](https://www.authelia.com/integration/openid-connect/clients/jellyfin/)
(tested there with SSO plugin 4.0.0.3) and the plugin's README. The image is pinned to
`jellyfin/jellyfin:10.11.11`: the plugin's newest release (4.0.0.4) is built for Jellyfin 10.11, and
Jellyfin 12 is too new for it so far.

## Who gets in

The roles come from Authelia groups (plugin settings, step 5):

| Authelia group | Jellyfin |
|---|---|
| `admins` | administrator |
| `family` | user, all libraries |

Someone in neither group is refused by the plugin. A Jellyfin user is created on someone's first
SSO login, named after their Authelia username; the plugin sets their admin rights on every login.

## Order after an update

`gateway/authelia/config/configuration.yml` now refers to `/secrets/jellyfin_client_digest` and
`gateway/docker-compose.yml` needs `JELLYFIN_HOST` in `gateway/.env`. Until both exist, `docker
compose` in `gateway/` refuses to run and Authelia won't start. Run `setup.sh` (step 2) **before**
restarting the gateway.

code-server and Vaultwarden were added in the same update and need the same. Run all three
`setup.sh` scripts (any order). Authelia keeps running with its old configuration until the last
one, which restarts it; the earlier ones print a note saying what is still missing.

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `jellyfin`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).

## 2. Start Jellyfin

```bash
cd apps/jellyfin
./scripts/setup.sh /srv/jellyfin/config /srv/jellyfin/cache /srv/data/media
sudo docker compose logs -f
```

The arguments are the config folder (database, users, plugins), the cache folder (transcodes,
images; the SSD is best) and the media folder (on the data disk, mounted read-only). All must be
absolute paths outside the repository; leave them out to be asked. The script

1. writes `.env` (after showing a summary) with your user and group,
2. creates the client secret if Authelia has none yet: the digest goes into
   `gateway/authelia/secrets/jellyfin_client_digest`; the plain secret is printed once at the end,
   for step 5, and stored nowhere else,
3. adds `JELLYFIN_HOST` to `gateway/.env` and recreates Authelia if either was new and nothing
   else is missing (this logs everyone out: sessions are kept in memory),
4. creates the config and cache folders (owned by you), and the media folder if it doesn't exist
   yet (an existing one is left as it is, with a note if Jellyfin can't read it), and checks that a
   container can reach Authelia,
5. starts Jellyfin and prints the values for step 5.

Running it again reuses `.env` and the digest.

## 3. Publish it

```bash
sudo tailscale serve --service=svc:jellyfin --https=443 http://127.0.0.1:8096
sudo tailscale serve status
```

If the service shows "Pending approval" in the admin console, approve it once.

## 4. First run

Open `https://<JELLYFIN_HOST>/`. Jellyfin's setup wizard:

1. Language, then a **local administrator**, e.g. `admin`, with a strong password (password
   manager). It is the way in if SSO breaks. Use a name nobody has in Authelia.
2. Libraries: add one per kind of media, with folders under `/media` (e.g. `/media/films` as
   "Movies", `/media/series` as "Shows").
3. Remote access: leave "Allow remote connections" on (tailnet devices count as remote).

## 5. SSO plugin

**Install.** Dashboard → Plugins → Repositories (in the catalog's settings) → add:

| Name | URL |
|---|---|
| SSO | `https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json` |

Save, then reload the plugin page. The plugin is listed as **SSO Authentication** under the category
"Authentication" (not "General"). Install it, then restart Jellyfin (`sudo docker compose restart`).

**If it isn't listed**, Jellyfin either couldn't fetch the repository or has no version of the plugin
for the running Jellyfin. From `apps/jellyfin`:

```bash
curl -s http://127.0.0.1:8096/System/Info/Public | jq -r .Version       # must be 10.11.x
sudo docker compose exec jellyfin curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json   # 200
sudo docker compose logs jellyfin | grep -iE 'manifest|repositor'          # fetch errors
```

- Version 12.x: the plugin has no build for it, so the catalog hides it. Use the pinned
  `10.11.11` image.
- No `200`: the container can't reach GitHub (DNS or internet from Docker). Fix that, or install by
  hand (below).
- A typo in the repository URL shows up as a fetch error in the log.

**Install by hand** (same files as the catalog; the zip includes Jellyfin's `meta.json`):

```bash
v=4.0.0.4
dir="<JELLYFIN_CONFIG_DIR>/plugins/SSO Authentication_$v"
curl -fL -o /tmp/sso.zip "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v$v/sso-authentication_$v.zip"
sudo mkdir -p "$dir" && sudo unzip -o /tmp/sso.zip -d "$dir" && sudo chown -R <JELLYFIN_UID_GID> "$dir"
sudo docker compose restart
```

It then shows under Dashboard → Plugins (installed) as SSO Authentication. Updates later come from
the catalog once the repository works, or the same way with a newer version number.

**Configure.** Dashboard → Plugins → SSO-Auth, add an OpenID provider:

| Setting | Value |
|---|---|
| Name of the OpenID Provider | `authelia` (it is part of the redirect URI; keep exactly this) |
| OpenID Endpoint | `https://<SERVER_NAME>/auth` |
| OpenID Client ID | `jellyfin` |
| OpenID Secret | the secret `setup.sh` printed (step 2) |
| Enabled | on |
| Enable Authorization by Plugin | on |
| Enable All Folders | on |
| Roles | `family` and `admins` |
| Admin Roles | `admins` |
| Role Claim | `groups` |
| Request Additional Scopes | `groups` |
| Set default username claim | `preferred_username` |
| Scheme Override | `https` (Jellyfin itself only sees plain HTTP from tailscale serve) |
| Disable Pushed Authorization | on (see below) |

Leave the rest as it is. Save.

Why Pushed Authorization is off: the plugin (4.0.0.4) bundles Duende OidcClient 6.0.1, which sends
the pushed authorization request with `client_secret_basic` but the token request with
`client_secret_post`. Authelia allows one method per client, so with it on the login fails with
"Error preparing login: Unauthorized - Failed to push authorization parameters" (Authelia's log:
"…using 'client_secret_basic', however the registered client with id 'jellyfin' is configured to
only support … 'client_secret_post'"). Switching Authelia to `client_secret_basic` would only move
the failure to the token request. With it off, the login is the plain code flow with PKCE and the
client secret, as for Immich. The library fixed this in April 2026; once a plugin release ships the
fix, it can be turned on again.

**Login button.** Dashboard → General → Branding → Login disclaimer:

```html
<form action="https://<JELLYFIN_HOST>/sso/OID/start/authelia">
  <button class="raised block emby-button button-submit">Log in with home account</button>
</form>
```

Save. The button shows on Jellyfin's login page, below the password form.

## 6. Apps and TVs: Quick Connect

The Jellyfin apps (Android, iOS, Android TV, …) can't open the SSO login. Check that Dashboard →
General → **Enable Quick Connect** is on, then on the device:

1. Add the server: `https://<JELLYFIN_HOST>` (in the tailnet) or `http://<LAN_IP>:8096` (home
   network only).
2. Choose **Quick Connect**; the app shows a code.
3. In a browser logged into Jellyfin (via the home account button): user menu → Quick Connect →
   enter the code. The device is now logged in as that user.

For a device without Quick Connect, an admin sets a Jellyfin password for that user (Dashboard →
Users → the user → Password); SSO users have none by default.

## 7. Test

1. `https://<JELLYFIN_HOST>/` → "Log in with home account" → gateway login → Jellyfin, logged in as
   your Authelia username. With `admins`, the Dashboard is in the menu; without, it isn't.
2. Someone in `family` sees all libraries; Quick Connect logs a phone app in as them.
3. `http://<LAN_IP>:8096` from the home network shows Jellyfin's login page.

## Logout

There is no `logoutUrl` in `web/apps.json`: Jellyfin keeps its token in the browser's storage for
`<JELLYFIN_HOST>`, not in a cookie, so a blind request from the landing page can't end it, and
Authelia 4.39 has no OpenID Connect logout. The landing page's "Log Out" doesn't end a Jellyfin
session; Jellyfin's own "Sign out" does. Jellyfin sessions don't expire by themselves; an admin
can end any of them under Dashboard → Devices.

## Backup

`JELLYFIN_CONFIG_DIR` (database, users, watch history, plugins and their settings) and `.env`. Stop
the container for a consistent copy (`sudo docker compose stop`). `JELLYFIN_CACHE_DIR` can be lost.
The media folder is backed up on its own (it is large and only read here). If the SSO secret is
lost, delete `gateway/authelia/secrets/jellyfin_client_digest`, run `setup.sh` again and enter the
new secret in the plugin.

## Notes and unverified items

- Not yet tested on the server: the plugin with Jellyfin 10.11.11 and Authelia 4.39. The plugin's
  issue tracker has open reports for 10.11 about roles not being applied; if admins don't get the
  Dashboard, check `sudo docker compose logs jellyfin` for the groups the plugin received.
- Unverified: what the plugin does when a local Jellyfin user already has the same name as an
  Authelia username (log in as that user, or refuse). Test with one account before relying on it.
- Before moving to Jellyfin 12, check that the plugin's manifest has a version for it
  (`targetAbi` in the manifest above); otherwise Jellyfin disables the plugin and only password and
  Quick Connect logins are left.
- Jellyfin sees every request coming from the Docker network's gateway address. For correct client
  addresses in its logs and activity, add that address under Dashboard → Networking → Known proxies
  (`sudo docker network inspect jellyfin_default -f '{{(index .IPAM.Config 0).Gateway}}'`).
- Port 8096 is published on all addresses, so the home network reaches Jellyfin without the gateway
  in between (plain HTTP, Jellyfin's own login). Nothing is reachable from the internet: no ports
  are forwarded on the router.
- Hardware transcoding on the GTX 1050 Ti needs the NVIDIA driver and Container Toolkit on the
  server; the block in `docker-compose.yml` is commented out until then.
