# RustDesk

Remote desktop between the family's computers (and phones), e.g. to help someone with their PC. The
server here only introduces the two devices (ID server, `hbbs`) and passes the connection on when
they can't reach each other directly (relay, `hbbr`). It runs from this folder's
`docker-compose.yml`.

RustDesk is not a web app and has no login: the RustDesk **clients** connect to the server's ports
directly, over the tailnet or the home network. Instead of a Tailscale Service and single sign-on,
it gets a help page on the gateway, `https://<SERVER_NAME>/rustdesk/` (the tile on the landing
page), that shows the settings for the clients. The server's key on that page is only shown to
logged-in family members.

```
RustDesk client ── <SERVER_NAME> or <LAN_IP> : 21115-21117 ──► hbbs (ID server) ┐ key pair in
                                                               hbbr (relay)     ┘ RUSTDESK_DATA_DIR
                    device A ◄──── direct, or through hbbr ────► device B (end-to-end encrypted)
help page   https://<SERVER_NAME>/rustdesk/       web/rustdesk/ (public)
            https://<SERVER_NAME>/rustdesk/key    Caddy, behind the login (group family)
```

| Piece | Where |
|---|---|
| Containers, settings | `apps/rustdesk/docker-compose.yml`, `.env` (from `.env.example`, not committed) |
| Server key pair | `<RUSTDESK_DATA_DIR>/id_ed25519` (private) and `id_ed25519.pub` (the key clients need) |
| Help page | `web/rustdesk/index.html`, `web/assets/rustdesk.js` |
| Key for the help page | `RUSTDESK_KEY` in `gateway/.env` (`setup.sh` adds it), served by `gateway/caddy/routes/rustdesk.caddy` |
| Who may see the key | `access_control` rule for `/rustdesk/key` in `gateway/authelia/config/configuration.yml` |
| Landing page tile | `web/apps.json` (entry `rustdesk`) |

## Who gets in

- **The server** accepts only clients that have its public key (`-k _` on both services). Anyone
  else who reaches the ports is refused. The ports are open to the tailnet and the home network, not
  to the internet (no ports are forwarded on the router).
- **A device** is controlled only with its own RustDesk password (or after the person at it clicks
  Accept). The server never sees those passwords or the screen contents: the connection is
  end-to-end encrypted between the two clients, also through the relay.
- **The key** on the help page: Authelia group `family`. Guests see the page without it.

## 1. Start the server

```bash
cd apps/rustdesk
./scripts/setup.sh /srv/data/rustdesk
sudo docker compose logs -f
```

The argument is the data folder (the server's key pair and the list of known devices), an absolute
path outside the repository; leave it out to be asked. The script

1. writes `.env` (after showing a summary),
2. creates the data folder and checks that ports 21115-21117 are free,
3. starts the relay first, which creates the key pair, then the ID server (so both use the same key),
4. puts the public key into `gateway/.env` as `RUSTDESK_KEY` and recreates Caddy (the help page
   shows it from there),
5. prints the client settings.

Running it again reuses `.env` and the key pair. No Tailscale Service is needed: tailscale serve
only forwards HTTPS, and the clients reach the ports on the server's own Tailscale address.

## 2. The help page

Already in place: `web/rustdesk/` (public, like the landing page) and the route for the key. After
the first `setup.sh`, check:

1. Logged in on the landing page, the RustDesk tile opens `https://<SERVER_NAME>/rustdesk/` with the
   server name and the key.
2. In a private window (not logged in), the same page shows the server name and a "Log in to see
   the key" button instead of the key.

## 3. Set up each client

Install RustDesk from [rustdesk.com](https://rustdesk.com/) (Windows, macOS, Linux, Android, iOS).
Then, in RustDesk: Settings (the ⋮ menu next to the ID on Windows) → **Network** → **ID/Relay server**:

| Field | Value |
|---|---|
| ID server | `<SERVER_NAME>` in the tailnet; `<LAN_IP>` for a device on the home network without Tailscale |
| Relay server | empty (the client uses the ID server's address, port 21117) |
| API server | empty (only for RustDesk's paid server) |
| Key | the key from the help page (or from `setup.sh`'s output) |

OK. At the bottom of the main window, "Ready" means the client is registered with the server. A
device in the tailnet needs Tailscale on to be reached; a device on the home network only while
it's at home.

On the computer that will be helped, set a permanent password (Settings → Security → Password) if
nobody will be there to click Accept.

## 4. Test

1. Two clients set up as above both show "Ready".
2. From one, enter the other's ID and connect: it asks for the password, then shows the screen.
3. A client without the key (or with a wrong one) shows "Key mismatch" and doesn't get an ID.

## Logout

Nothing to log out from: neither the server nor the help page has a session of its own.

## Backup

`RUSTDESK_DATA_DIR` (above all `id_ed25519` and `id_ed25519.pub`) and `.env`. If the key pair is
lost, the server makes a new one, and every client must be given the new key: run `setup.sh` again
(it updates `RUSTDESK_KEY` for the help page) and change the Key field on each device.

## Notes and unverified items

- Checked against the rustdesk-server 1.1.16 source: `hbbs` refuses clients with a different key by
  default; `hbbr` only does with `-k` (hence `-k _`, which means "this server's key"). Checked
  against the RustDesk client source: an empty relay field means the ID server's host on port 21117.
  Not yet tested on the server.
- Unverified on the server: hole punching (direct connections) between tailnet devices through
  Docker's port forwarding. If every connection goes through the relay, it still works, just with
  everything passing through the server.
- Ports 21118 and 21119 (RustDesk's web client) are not published; the web client needs RustDesk's
  paid server here.
- The landing page's status dot for this tile only shows that the help page answers, not the
  RustDesk server. Kuma can watch the ports (TCP port monitors on `<SERVER_NAME>` 21116 and 21117).


## Client
- [Unattended access](https://rustdesk.com/blog/rustdesk-unattended-access-setup/?lang=en)
- [UA-Wayland](https://rustdesk.com/blog/unattended-remote-access-wayland/?lang=en)
- [Linux Guide](https://rustdesk.com/blog/rustdesk-for-linux/?lang=en)

1. Download the [Wayland Unattended Access build](https://rustdesk.com/blog/unattended-remote-access-wayland/?lang=en) on the server
2. Settings -> Network -> ID/Relay Server :: Change hosting server to self hosting (with the credentials available in the web app) 
3. Settings -> Security -> Set Permanent Password :: Add a secure static password
4. Install RustDesk Client on the other machine, repeat step (2) and connect to the server with the displayed server ID and the password set at step (3) 