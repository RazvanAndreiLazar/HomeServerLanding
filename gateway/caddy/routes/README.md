# Path routes

Each `*.caddy` file in this folder adds one app on a path of the main address
(`https://<SERVER_NAME>/<path>`). The Caddyfile imports them inside the `:8080` site.

Example, `files.caddy`:

```caddy
handle /files* {
	import protected                    # login required (Authelia forward_auth)
	reverse_proxy filebrowser:80
}
```

`import protected` needs a matching rule under `access_control` in
`../../authelia/config/configuration.yml`, otherwise Authelia refuses every request
(`default_policy: deny`). Leave it out for a public route.

After adding or changing a file: `sudo docker compose restart caddy`.
Full checklist: [docs/adding-an-app.md](../../../docs/adding-an-app.md).
