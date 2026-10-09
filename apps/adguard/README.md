# AdGuard Home

DNS for the whole household with ad and tracker blocking. Every device in the tailnet uses it (on
any network, through Tailscale's DNS settings), and so does every device on the home network
(through the router). It runs from this folder's `docker-compose.yml`. Its web interface has its
own address, `https://<ADGUARD_HOST>/` (`adguard.<tailnet>.ts.net`), as a Tailscale Service, and
only Authelia users in the group `admins` get in.

Like Kuma, the web interface sits behind [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/),
which logs in through Authelia (single sign-on). AdGuard's own login is turned off (`setup.sh` does
this), so admins log in once. The DNS service itself has no login: it answers anyone who can reach
port 53, which is the point.

```
DNS  tailnet device → MagicDNS (100.100.100.100) → <server's Tailscale IP>:53 ─┐
     home network device (router's DHCP hands out LAN_IP) → <LAN_IP>:53 ──────┴→ adguard:53
                                                                                   └→ upstream (DNS over HTTPS)
Web  https://<ADGUARD_HOST>/   tailscale serve --service=svc:adguard → 127.0.0.1:4182
       oauth2-proxy            no session → login at https://<SERVER_NAME>/auth
       └─ group admins  →      http://adguard:3000 (compose network only)
```

| Piece | Where |
|---|---|
| Containers, settings | `apps/adguard/docker-compose.yml`, `.env` (from `.env.example`, not committed) |
| AdGuard's own settings | `<ADGUARD_DATA_DIR>/conf/AdGuardHome.yaml` (edited through the web interface) |
| OIDC client (uses policy `admins_only`) | `apps/adguard/authelia-clients.yml`, already in `gateway/authelia/config/configuration.yml` |
| Client secret digest | `gateway/authelia/secrets/adguard_client_digest` (not committed; `setup.sh` creates it) |
| Host name for Authelia | `ADGUARD_HOST` in `gateway/.env` (`setup.sh` adds it) |
| Landing page tile + logout URL | `web/apps.json` (entry `adguard`) |

## Who gets in

- **Web interface:** the group `admins`, checked by Authelia (policy `admins_only`) and again by
  oauth2-proxy (`OAUTH2_PROXY_ALLOWED_GROUPS`), as for Kuma. Everyone sees the tile on the landing
  page; non-admins are refused when they open it.
- **DNS:** every device that sends it queries (tailnet and home network). Nothing is reachable from
  the internet: no ports are forwarded on the router.

## Order after an update

`gateway/authelia/config/configuration.yml` now refers to `/secrets/adguard_client_digest` and
`gateway/docker-compose.yml` needs `ADGUARD_HOST` in `gateway/.env`. Until both exist, `docker compose`
in `gateway/` refuses to run and Authelia won't start. Run `setup.sh` (step 2) **before** restarting
the gateway; it creates both and restarts Authelia itself.

## 1. Tailscale Service

Admin console → Services → Advertise → Define a Service: name `adguard`, endpoint `tcp:443`,
tag `tag:server-svc` (needs [setup step 1](../../docs/setup.md#1-prepare-tailscale-for-named-services)).

## 2. Start AdGuard

```bash
cd apps/adguard
./scripts/setup.sh /srv/data/adguard
sudo docker compose logs -f
```

The argument is AdGuard's data folder (`conf/` for its settings, `work/` for the query log,
statistics and filter lists), an absolute path outside the repository; leave it out to be asked.
The script

1. writes `.env` (after showing a summary) and generates oauth2-proxy's cookie secret,
2. generates the client secret: the plain one goes into `.env` (oauth2-proxy needs it), the digest
   into `gateway/authelia/secrets/adguard_client_digest`,
3. adds `ADGUARD_HOST` to `gateway/.env` and recreates Authelia if either was new
   (this logs everyone out: sessions are kept in memory),
4. creates the data folders, checks that port 53 is free on the server and that a container can
   reach Authelia,
5. starts AdGuard and oauth2-proxy,
6. on the first run, completes AdGuard's setup wizard through its API (web interface on port 3000,
   DNS on port 53, all addresses) and then removes the user the wizard requires, which turns
   AdGuard's own login off.

Running it again reuses `.env`, the digest and AdGuard's settings. To check Authelia:
`cd gateway && sudo docker compose logs --tail=20 authelia` should end with "Startup complete".

**Port 53 in use:** the script stops and shows what holds it. On Debian that is usually
systemd-resolved's stub listener (set `DNSStubListener=no` in `/etc/systemd/resolved.conf`, then
`sudo systemctl restart systemd-resolved`) or a dnsmasq started by libvirt.

## 3. Publish the web interface

```bash
sudo tailscale serve --service=svc:adguard --https=443 http://127.0.0.1:4182
sudo tailscale serve status
```

If the service shows "Pending approval" in the admin console, approve it once.

## 4. Settings in the web interface

Open `https://<ADGUARD_HOST>/` as an admin. You go through the gateway login page (or straight in
when already logged in on the landing page) and land on AdGuard's dashboard.

**Settings → DNS settings:**

| Setting | Value |
|---|---|
| Upstream DNS servers | `https://dns10.quad9.net/dns-query` and `https://cloudflare-dns.com/dns-query`, one per line (encrypted, so the ISP doesn't see the lookups) |
| Upstream mode | Parallel requests (the faster answer wins; still works if one is down) |
| Fallback DNS servers | `9.9.9.10` and `1.1.1.1` (used only when every upstream fails) |
| Bootstrap DNS servers | keep the defaults (plain IP addresses, needed to find the DoH servers) |
| Rate limit | keep 20; raise it if a device shows "rate limited" in the query log |
| Enable DNSSEC | on |
| Cache size | keep the default; turn on **Optimistic caching** for faster repeat lookups |

Press **Test upstreams**, then **Save** in each section.

**Filters → DNS blocklists:** the *AdGuard DNS filter* is on by default. Add list → Choose from the
list → add one more broad list, e.g. *HaGeZi's Multi NORMAL* or *OISD Small*. More lists block more
but also break more sites; start with two. **Filters → DNS allowlists** or the query log's
**Unblock** button fix false positives.

**Settings → General settings:**

| Setting | Value |
|---|---|
| Query log retention | 7 days (each lookup is a line on the SSD) |
| Statistics retention | 30 days |
| Block domains using filters and hosts files | on (default) |
| Safe search / parental control | optional, per household |

**Settings → Client settings** (optional): add each device as a persistent client with its
Tailscale IP (`tailscale status` on the server lists them) or its LAN address, so the query log and
statistics show names instead of addresses. Per-client settings (e.g. different blocklists for
children's devices) are set here too.

## 5. Test

Before pointing any device at it (steps 6 and 7), check that it answers. From the server or any
tailnet device:

```bash
dig +short example.com @<server's Tailscale IP>         # an address: AdGuard resolves
dig +short doubleclick.net @<server's Tailscale IP>     # 0.0.0.0: AdGuard blocks
dig +short example.com @<LAN_IP>                        # same from the home network
```

(`tailscale ip -4` on the server shows its Tailscale IP. Without `dig`: `nslookup example.com <ip>`.)

The lookups show up in Query log with the asking device's address. Then the web interface:

1. Admin: `https://<ADGUARD_HOST>/` opens AdGuard after the gateway login, without a second login.
2. A family member without `admins`: Authelia refuses the login.

## 6. Use it in the tailnet

Tailscale admin console → **DNS**:

1. **Nameservers** → Global nameservers → Add nameserver → Custom → the server's Tailscale IPv4
   address → Save.
2. Turn on **Override DNS servers** (called "Override local DNS" in older consoles). Without it,
   devices keep using their local network's DNS and only fall back to AdGuard.
3. Leave **MagicDNS** on: `*.ts.net` names (the gateway and every app) are still answered by
   Tailscale itself, and everything else goes to AdGuard.

Devices need Tailscale's DNS settings accepted: on by default in the phone, Windows and macOS apps
("Use Tailscale DNS settings"); on Linux, `sudo tailscale set --accept-dns=true`. The server itself
also uses it.

Check on a device: open a few websites, then look for the device's Tailscale IP in Query log.

## 7. Use it on the home network

For devices that are not in the tailnet (TV, consoles, guests' phones on the Wi-Fi):

1. Give the server a fixed address on the home network: a DHCP reservation in the router for the
   server's network card, matching `LAN_IP` in `gateway/.env`.
2. In the router's DHCP (or LAN) settings, set the DNS server to `LAN_IP`. Devices pick it up when
   they renew their address (reconnect the Wi-Fi, or wait).
3. Leave the secondary DNS empty, or set it to `LAN_IP` too. A public secondary (e.g. `1.1.1.1`)
   means devices often skip AdGuard and ads come back.
4. If the router hands out IPv6, it may also advertise its own IPv6 DNS server, which devices
   prefer and which bypasses AdGuard. Turn off "advertise DNS" for IPv6 / RDNSS in the router, or
   set it to the server's IPv6 address (Docker forwards port 53 on IPv6 too; unverified on the
   server).

Router menus differ by brand; the setting is usually under LAN → DHCP server → DNS server.

## When AdGuard is down

Every device that uses it loses DNS for everything except `*.ts.net` names: websites stop loading
while Tailscale itself keeps working. `restart: unless-stopped` brings AdGuard back after a crash or
reboot. To take it out of the path (e.g. for a longer outage or to compare):

- Tailnet: admin console → DNS → remove the nameserver (or turn off Override DNS servers).
- Home network: set the router's DHCP DNS back to automatic / the router's own address.

## Logout

The landing page's "Log Out" ends the Authelia session and then sends a blind
`POST https://<ADGUARD_HOST>/oauth2/sign_out` (the `logoutUrl` in `web/apps.json`), which clears
oauth2-proxy's cookie, as for Kuma. AdGuard has no session of its own (login off). oauth2-proxy's
session lasts up to 24 hours (`OAUTH2_PROXY_COOKIE_EXPIRE`) if you don't log out.

## Backup

`ADGUARD_DATA_DIR/conf` (all settings, including blocklists and clients) and `.env`. The `work`
folder holds only the query log, statistics and downloaded lists; it is rebuilt by itself. Stop the
containers for a consistent copy (`sudo docker compose stop`). The digest in
`gateway/authelia/secrets/` is backed up with the gateway; if it is lost, delete
`ADGUARD_CLIENT_SECRET` from `.env` and run `setup.sh` again.

## Notes and unverified items

- With its login off, AdGuard's web interface trusts every request that reaches port 3000. Only
  oauth2-proxy can reach it from outside the server, but the container's address is reachable from
  the server itself, so a local user on the server could change DNS settings. Same trade-off as
  Kuma.
- To turn AdGuard's own login back on: stop AdGuard, replace `users: []` in `AdGuardHome.yaml` with
  a user (`name:` plus a bcrypt `password:`, e.g. from `htpasswd -nbB admin '<password>'`, the part
  after the colon), start it again. Admins then log in twice. `setup.sh` leaves an existing
  `AdGuardHome.yaml` alone.
- Checked against the AdGuard Home v0.107.79 source: no users means no login; the setup wizard's API
  accepts keeping the web interface on port 3000. Not yet tested on the server.
- Unverified on the server: that AdGuard sees each device's own address. Queries arriving from the
  tailnet or the home network go through Docker's port forwarding, which keeps the sender's address;
  lookups from the server itself show the Docker network's gateway address instead.
- AdGuard's DHCP server is not used (it would need the host network); the router keeps handing out
  addresses.
- DNS over HTTPS/TLS towards the devices is not set up: tailnet traffic is already encrypted by
  WireGuard, and the home network is trusted.
- The web interface's port 4182 is bound to `127.0.0.1` only, so there is no "Open on home network"
  link.
