# Monitoring: setting it up in the web interfaces

What to configure inside Uptime Kuma and Beszel once both are running
([apps/kuma](../apps/kuma/README.md), [apps/beszel](../apps/beszel/README.md)). Both are only
reachable for the group `admins`.

| | Answers | Checks from |
|---|---|---|
| Uptime Kuma | Is each service up and answering? Is the certificate valid? Did the backup run? | Inside its container, like a client would |
| Beszel | How is the machine doing (CPU, memory, disks, temperatures, containers)? | The agent on the server |

Set up notifications first (step 1 in each part), so every monitor or alert you add can use them.

---

## Uptime Kuma

### 1. Notifications

Settings → Notifications → Setup Notification:

1. Pick a channel everyone on the admin side already reads: ntfy (app on the phone, a topic on
   ntfy.sh or your own server), Telegram, Matrix, Discord or email (SMTP).
2. Fill in the channel's fields and press **Test**.
3. Tick **Default enabled** (new monitors use it) and **Apply on all existing monitors**.

### 2. General settings

| Setting | Where | Value |
|---|---|---|
| Display timezone | Settings → General | your timezone (times in notifications) |
| History | Settings → Monitor History | 90 days is plenty; less database on the SSD |
| Docker host | Settings → Docker Hosts → Setup Docker Host | name `server`, connection type **Socket**, path `/var/run/docker.sock` |

The Docker host only works because `apps/kuma/docker-compose.yml` mounts the Docker socket.

### 3. Monitors

Add New Monitor for each row. Keep the default interval (60 s) and set **Retries** to 2, so a
single slow answer doesn't wake anyone.

**What users see** (the full path: Tailscale, HTTPS, Caddy or the app):

| Name | Type | URL | Keyword / note |
|---|---|---|---|
| Landing page | HTTP(s) | `https://<SERVER_NAME>/` | |
| Authelia | HTTP(s) - Keyword | `https://<SERVER_NAME>/auth/api/health` | `OK` |
| Immich | HTTP(s) - Keyword | `https://<IMMICH_HOST>/api/server/ping` | `pong` |
| OpenCloud | HTTP(s) - Keyword | `https://<OPENCLOUD_HOST>/status.php` | `"installed":true` |
| Beszel | HTTP(s) - Keyword | `https://<BESZEL_HOST>/ping` | `OK` (oauth2-proxy's health check; no login needed) |

For each of them, under Advanced, tick **Certificate Expiry Notification**. `tailscale serve`
renews the certificates itself; this tells you if it ever stops.

Kuma checks from inside its container, so the names must resolve there. Test once from the
server before adding the monitors:

```bash
sudo docker run --rm curlimages/curl:8.10.1 -sS -o /dev/null -w '%{http_code}\n' https://<IMMICH_HOST>/api/server/ping
```

`200` is good. A name-resolution error means the container can't see MagicDNS: add the names
under `extra_hosts` for the `kuma` service (as for oauth2-proxy in its compose file), or rely on
the container monitors below for that app.

**What runs on the server** (type Docker Container, Docker host `server`):

| Name | Container |
|---|---|
| Caddy | `gateway-caddy-1` |
| Authelia | `gateway-authelia-1` |
| Immich server | `immich_server` |
| Immich database | `immich_postgres` |
| OpenCloud | `opencloud-opencloud-1` |
| Beszel hub | `beszel-beszel-1` |
| Beszel agent | `beszel-beszel-agent-1` |

The names come from the compose project (the folder name) and the service; check them with
`sudo docker ps --format '{{.Names}}'`. A container monitor only says "running", while the HTTP
monitors above say "answering". Together they show whether a problem is the app or the way to it.

**Jobs that should run regularly** (type Push), e.g. a nightly backup:

1. Add New Monitor → Push, name e.g. "Backup", **Heartbeat Interval** a bit longer than the job's
   schedule (daily job: 90000 s = 25 h).
2. Copy the Push URL and call it at the end of the job, only when it succeeded:

   ```bash
   curl -fsS -m 10 "https://<KUMA_HOST>/api/push/<token>?status=up&msg=OK" >/dev/null
   ```

If the job doesn't report in time, Kuma alerts. `/api/push/` is the only path of Kuma that
oauth2-proxy lets through without login.

### 4. Optional

- **Maintenance** (left menu): planned downtime, e.g. while upgrading Immich, so no alerts fire.
- **Status pages** work, but are behind the admins-only login like the rest of Kuma, so they
  can't be shown to the family as is.

---

## Beszel

The server was added during setup (Add System, host `/beszel_socket/beszel.sock`). Container
stats appear on its page by themselves (the agent reads the Docker socket).

### 1. Notifications

Settings (top right, your avatar) → Notifications. Settings here belong to your Beszel user;
each admin sets their own.

- **Webhook / push**: Add URL, as a [Shoutrrr](https://shoutrrr.nickfedor.com/) URL, then
  **Test URL**. Examples: `ntfy://ntfy.sh/<topic>`, `telegram://<token>@telegram?chats=<chat-id>`,
  `discord://<token>@<webhook-id>`.
- **Email**: enter addresses here, but Beszel only sends mail once an SMTP server is set in the
  admin UI (`https://<BESZEL_HOST>/_/` → Settings → Mail settings, log in with
  `BESZEL_ADMIN_EMAIL` / `BESZEL_ADMIN_PASSWORD` from `apps/beszel/.env`).

Save.

### 2. Alerts

On the systems table, the bell icon on the server's row. Each alert has a threshold and a
duration ("for at least N minutes"), so short spikes don't fire.

| Alert | Suggested | Why |
|---|---|---|
| Status | on | Agent unreachable: the server or the agent is down |
| CPU | 90 % for 10 min | The i5-750 is slow; brief 100 % (Immich imports) is normal |
| Memory | 90 % for 10 min | 12 GB, Immich's machine learning takes a large share |
| Disk | 85 % | Applies to every disk Beszel shows (system SSD and extra filesystems) |
| Temperature | 80 °C for 5 min | Old hardware, dust; pick the CPU sensor on the system page if several show |
| Load average (5 min) | 6 for 10 min | 4 cores; sustained load above that means things are queueing |
| Bandwidth | off | The server is a Tailscale exit node; family traffic would trigger it |

The values are starting points: watch the charts for a week and adjust.

### 3. Settings

Settings → General: chart time span, units (°C, bytes or bits for network) and language, per user.

### 4. What needs a compose change, not the web interface

Kept out of the default setup; each means editing `apps/beszel/docker-compose.yml`:

- **Data disk usage**: mount a folder of the disk under `/extra-filesystems/` in the agent
  (example in the compose file). Without it, only the system disk is shown.
- **S.M.A.R.T. (disk health)**: the agent needs access to the disk devices (and `SYS_RAWIO`/
  `SYS_ADMIN` capabilities); see Beszel's docs on S.M.A.R.T.
- **GPU** (GTX 1050 Ti): needs the `henrygd/beszel-agent-nvidia` image and the NVIDIA container
  runtime.
- **Beszel watching itself**: the hub can ping a Kuma Push monitor (`HEARTBEAT_URL` in the
  `beszel` service), so Kuma alerts when Beszel stops.

---

## Other admins

- Kuma has no own users (its login is off); every `admins` member sees the same monitors.
- Beszel needs a Beszel user per admin with their Authelia email
  ([apps/beszel, "Who gets in"](../apps/beszel/README.md#who-gets-in)). Notifications and alerts
  are per user; systems are shared only if the system is shared with them (system menu → edit →
  users), or for everyone with `SHARE_ALL_SYSTEMS=true` in the compose file.

## Not verified

- The OpenCloud `status.php` keyword and the container names are the usual ones; check them on
  the server.
- Whether Kuma's container resolves the `*.ts.net` service names without `extra_hosts` (test
  command in Kuma step 3).
