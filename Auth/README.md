# Gateway: Caddy + Authelia

Everything lives in `/opt/gateway` on the server.
Replace `home.tail8154a2.ts.net` with the machine's full Tailscale name everywhere
(Caddyfile: 1 place, configuration.yml: 4 places). Find it with `sudo tailscale status --json | jq -r .Self.DNSName`
(drop the trailing dot).

## 1. Copy the folder to the server

From the laptop, after unzipping:

    scp -r gateway <user>@192.168.0.200:/tmp/

On the server:

    sudo mv /tmp/gateway /opt/gateway
    sudo chown -R root:root /opt/gateway

## 2. Set the machine name

    cd /opt/gateway
    NAME=$(sudo tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    echo "$NAME"                                   # check it looks like server.tailXXXX.ts.net
    sudo sed -i "s/home.tail8154a2.ts.net/$NAME/g" caddy/Caddyfile authelia/config/configuration.yml
    grep -rn "SERVER.TAILNET" . || echo "all replaced"

## 3. Generate the three secrets

    sudo mkdir -p authelia/secrets
    for s in jwt session storage; do sudo sh -c "openssl rand -hex 64 > authelia/secrets/$s"; done
    sudo chmod 700 authelia/secrets && sudo chmod 600 authelia/secrets/*

Back these up. Losing `storage` makes Authelia's database unreadable (only remember-me
and similar state, no user data, but it will refuse to start until you reset it).

## 4. Create your user

    sudo docker run --rm -it authelia/authelia:4.39 authelia crypto hash generate argon2

Type the password when prompted, copy the `$argon2id$...` line into
`authelia/config/users_database.yml` in place of `$argon2id$PASTE_HASH_HERE`.
Repeat per family member. Protect the file:

    sudo chmod 600 authelia/config/users_database.yml

## 5. Start

    sudo docker compose up -d
    sudo docker compose logs -f authelia            # wait for "Startup complete", Ctrl+C to leave

If Authelia exits, the log names the setting it rejects. Fix it and run `up -d` again.

## 6. Point Tailscale at Caddy

    sudo tailscale serve status                     # note what / serves today
    sudo tailscale serve --bg http://127.0.0.1:8080
    sudo tailscale serve status

The landing page in `/srv/landing` is now served by Caddy instead of directly by Tailscale.

## 7. Test, in this order

1. `https://NAME/` shows the landing page without logging in (guest view).
2. `https://NAME/whoami` redirects to the login page at `/auth`.
3. Log in with "Remember me" ticked. You return to `/whoami`, and the page lists
   a `Remote-User: vasile` header. That proves the whole chain works.
4. Close the browser, reopen `/whoami`: still logged in (remember me).
5. `https://NAME/auth/logout` logs out; `/whoami` asks for login again.
6. Five wrong passwords in a row: the account is blocked for 15 minutes.

## 8. Clean up after testing

Remove the `whoami` service from docker-compose.yml, its `handle /whoami*` block from the
Caddyfile and its rule from configuration.yml, then:

    sudo docker compose up -d --remove-orphans

## Adding a user later

Add a block to `users_database.yml` with a new hash. Authelia picks it up without a restart.

## Backup

Include `/opt/gateway` in the server backup. The important files are `authelia/secrets/*`,
`authelia/config/users_database.yml` and `authelia/config/db.sqlite3`.