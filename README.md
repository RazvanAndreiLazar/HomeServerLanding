# HomeServerLanding

Entry point for a home server reachable only inside a Tailscale tailnet. Family members log in
once and reach the landing page and every app with the same account. Guests see the landing
page without logging in.

```
device (in tailnet)
  │
  ├─ https://<SERVER_NAME>/          tailscale serve → Caddy :8080
  │     /            landing page (public)
  │     /auth/       login page (public; calls Authelia's API)
  │     /auth/*      Authelia: API, single sign-on provider, logout
  │     /config.json machine-specific values for the pages
  │     /<path>/*    path-routed apps behind the login (gateway/caddy/routes)
  │
  └─ https://<app>.<tailnet>.ts.net/  Tailscale Service → the app directly
                                      login via Authelia (OpenID Connect), e.g. Immich
```

| Component | Role |
|---|---|
| Tailscale Serve | HTTPS with a valid certificate, no open ports on the router |
| Caddy | Serves the web pages, routes path apps, asks Authelia before passing protected requests |
| Authelia | Users, passwords, sessions ("remember me"), single sign-on for apps |
| Web pages | Landing and login pages sharing one theme |

## Layout

```
gateway/                docker compose project: Caddy + Authelia (run commands from here)
  .env.example          machine-specific values (copy to .env)
  caddy/Caddyfile       main routing
  caddy/routes/         one file per path-routed app
  authelia/config/      configuration.yml, users_database.example.yml
  authelia/assets/      logo and favicon for Authelia's own pages
  scripts/              create_secrets.sh
web/                    everything here is public
  index.html            landing page
  login/                login page
  apps.json             the app list (tiles, logout URLs)
  assets/               theme.css (shared look), common.js, page scripts
apps/<app>/README.md    per-app setup (Tailscale Service, OIDC client, app settings)
docs/                   setup guide, adding an app, decisions and open items
```

Not committed, created on the server: `gateway/.env`, `gateway/authelia/secrets/*`,
`gateway/authelia/config/users_database.yml` and Authelia's database.

## Docs

- [Setup](docs/setup.md): from a fresh server to a working gateway, plus day-to-day tasks and backup
- [Adding an app](docs/adding-an-app.md): path-routed or own address with single sign-on
- [Decisions and open items](docs/decisions.md)
- [Monitoring](docs/monitoring.md): monitors and alerts in Uptime Kuma and Beszel
- Apps: [Immich](apps/immich/README.md), [OpenCloud](apps/opencloud/README.md),
  [Uptime Kuma](apps/kuma/README.md), [Beszel](apps/beszel/README.md)
