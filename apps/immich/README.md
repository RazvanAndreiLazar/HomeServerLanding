# Immich

Photos and videos. Runs from its own `docker-compose.yml` (container `immich_server`, port 2283),
outside this repository. It has its own address, `https://<IMMICH_HOST>/`
(`immich.<tailnet>.ts.net`), as a Tailscale Service. Family members log in through Authelia
(OpenID Connect).

| Piece | Where |
|---|---|
| Landing page tile + logout URL | `web/apps.json` (entry `immich`) |
| OIDC client | `gateway/authelia/config/configuration.yml` → `identity_providers.oidc.clients` |
| Client secret digest | `gateway/authelia/secrets/immich_client_digest` (not committed) |
| Host name | `IMMICH_HOST` in `gateway/.env` |

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `immich`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).
Then on the server:

```bash
sudo tailscale serve --service=svc:immich --https=443 http://127.0.0.1:2283
sudo tailscale serve status
```

This serves Immich at `https://<IMMICH_HOST>/` (port 443 outside, so no port in the address; 2283 inside).
If the service shows "Pending approval" in the admin console, approve it once.

## 2. Client secret

From `gateway/`:

```bash
sudo docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 \
  --variant sha512 --random --random.length 72 --random.charset rfc3986
```

Keep the `Random Password` for step 4 (it goes into Immich; no need to store it anywhere else).
Save the digest, keeping the single quotes:

```bash
printf '%s' '$pbkdf2-sha512$...whole digest...' | sudo tee authelia/secrets/immich_client_digest >/dev/null
sudo chmod 600 authelia/secrets/immich_client_digest
sudo docker compose restart authelia
```

## 3. Check that Immich can reach Authelia

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

## 4. Immich OAuth settings

Administration → Settings → Authentication Settings → OAuth:

| Setting | Value |
|---|---|
| Enable | on |
| Issuer URL | `https://<SERVER_NAME>/auth/.well-known/openid-configuration` |
| Client ID | `immich` |
| Client Secret | the `Random Password` from step 2 |
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

## Logout

There is no single logout between Authelia 4.39 and Immich. The landing page's "Log Out" sends a
blind `POST https://<IMMICH_HOST>/api/auth/logout` (the `logoutUrl` in `web/apps.json`) before
ending the Authelia session. Immich's own "Log out" button ends only Immich's session; with Auto
launch on, the user is logged straight back in while the Authelia session lasts.

## Notes

- Don't put `forward_auth` in front of Immich: it breaks the mobile app.
- Unverified: whether the browser sends Immich's cookie on the cross-host logout request, and
  whether Immich honours `?autoLaunch=0`. See [decisions.md](../../docs/decisions.md#open-items).
