# Adding an app

There are two ways to publish an app. Choose by how the app handles login.

| | A. Path on the main address | B. Own address + single sign-on |
|---|---|---|
| Address | `https://<SERVER_NAME>/<path>` | `https://<app>.<tailnet>.ts.net/` |
| Login | Caddy asks Authelia first (`forward_auth`) | The app logs in via Authelia (OpenID Connect) |
| Fits | Apps without their own login, or that accept `Remote-User` headers; must work under a sub-path | Apps with OIDC support, mobile apps, apps that need the root path |
| Example | File Browser | Immich |

Every app also gets an entry in `web/apps.json` and, ideally, a folder `apps/<app>/README.md`
with its own setup notes (see [Immich](../apps/immich/README.md)).

## A. Path on the main address

1. Run the app in a container that Caddy can reach. The simplest is to add it to
   `gateway/docker-compose.yml`. An app in another compose project must join a shared network.
2. Create `gateway/caddy/routes/<app>.caddy`:

   ```caddy
   handle /files* {
   	import protected
   	reverse_proxy filebrowser:80
   }
   ```

   Leave out `import protected` for a public route.
3. Add a rule in `gateway/authelia/config/configuration.yml` (anything without a rule is denied):

   ```yaml
   access_control:
     default_policy: 'deny'
     rules:
       - domain: '{{ env "SERVER_NAME" }}'
         resources:
           - '^/files([/?].*)?$'
         subject: 'group:family'
         policy: 'one_factor'
   ```

   The app receives `Remote-User`, `Remote-Groups`, `Remote-Name` and `Remote-Email` headers.
4. `sudo docker compose up -d && sudo docker compose restart caddy`
5. Add the tile (step "Landing page tile" below), with `"url": "/files/"`.

## B. Own address and single sign-on

1. Define a Tailscale Service for the app and serve it:
   `sudo tailscale serve --service=svc:<app> --https=443 http://127.0.0.1:<port>`
   (as in [Immich step 1](../apps/immich/README.md#1-tailscale-service)).
2. Generate a client secret and save its digest as `gateway/authelia/secrets/<app>_client_digest`
   (as in [Immich step 2](../apps/immich/README.md#2-client-secret)).
3. Add the host to `gateway/.env` (e.g. `PAPERLESS_HOST=docs.<tailnet>.ts.net`). Also add it
   to the `authelia` service's `environment` in `docker-compose.yml`, the way `IMMICH_HOST` is.
4. Add a client under `identity_providers.oidc.clients` in `configuration.yml`. Copy the
   `immich` block, then change `client_id`, `client_name`, the digest file, `redirect_uris`
   (from the app's documentation) and `token_endpoint_auth_method` (what the app supports).
5. `sudo docker compose up -d` (Authelia validates the config at start; check the logs).
6. Configure the app's OpenID Connect settings with issuer
   `https://<SERVER_NAME>/auth/.well-known/openid-configuration`.
7. Add the tile, including `logoutUrl` if the app has an API endpoint that ends its session.

## Landing page tile

Add an entry to `web/apps.json`. No restart needed.

```json
{
  "id": "paperless",
  "name": "Paperless",
  "icon": "📄",
  "description": "Documents",
  "url": "https://docs.{tailnet}",
  "lanUrl": "http://{lan}:8000"
}
```

| Field | |
|---|---|
| `id`, `name`, `icon`, `description` | Shown on the tile (`icon` is an emoji) |
| `url` | Where the tile links for logged-in users; also used for the status dot |
| `guestUrl` | Optional: link for visitors who aren't logged in |
| `lanUrl` | Optional: "Open on home network" link; omitted when `LAN_IP` is empty |
| `logoutUrl` | Optional: receives a blind `POST` with the app's cookies on "Log Out" |

`{tailnet}` (e.g. `tailXXXX.ts.net`) and `{lan}` (`LAN_IP`) are filled in from `/config.json`, so
no machine-specific values are committed.

## Style

Pages served by the gateway link `/assets/theme.css` (and `/assets/common.js` for config and
login state). Put any new page under `web/`, using the existing classes (`.btn`, `.card`,
`.panel`, `.field`, `.alert`) and color variables.
