#!/bin/bash
# Prepares and starts Immich. Run on the server; safe to run again.
#
#   ./scripts/setup.sh [UPLOAD_LOCATION] [DB_DATA_LOCATION]
#
#   1. creates .env from .env.example on the first run (folders from the arguments or asked for,
#      timezone from the server, database password generated). Stops if Immich already runs
#      from another folder (see ../README.md, "Moving an existing installation").
#   2. creates the OIDC client secret if Authelia has none yet: the digest goes into
#      gateway/authelia/secrets/immich_client_digest, the plain secret is printed once for
#      Immich's OAuth settings (it is not stored anywhere)
#   3. adds IMMICH_HOST to gateway/.env and restarts Authelia if anything was new
#   4. creates the folders and checks that a container can reach Authelia
#   5. starts Immich and prints the tailscale serve command
# The Tailscale Service and Immich's OAuth settings are separate steps (see ../README.md).
set -euo pipefail

app="$(cd "$(dirname "$0")/.." && pwd)"
gateway="$(cd "$app/../../gateway" && pwd)"
digest_file="$gateway/authelia/secrets/immich_client_digest"
cd "$app"

# Replaces KEY=... in .env with KEY='value' (single quotes: literal for both bash and docker compose).
set_env() {
    local key=$1 value=$2 line tmp
    tmp=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line == "$key="* ]]; then
            printf "%s='%s'\n" "$key" "$value"
        else
            printf '%s\n' "$line"
        fi
    done < .env > "$tmp"
    cat "$tmp" > .env
    rm -f "$tmp"
}

# Asks for a value with a default, unless one was given as an argument.
ask() {
    local prompt=$1 default=$2 given=${3:-} answer
    if [ -n "$given" ]; then printf '%s' "$given"; return; fi
    read -rp "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

check_dir() {
    local name=$1 dir=$2
    if [[ $dir != /* ]]; then echo "$name must be an absolute path: $dir" >&2; exit 1; fi
    if [[ $dir == *"'"* ]]; then echo "$name must not contain a single quote" >&2; exit 1; fi
    case "$(realpath -m "$dir")" in
        "$(realpath -m "$app/../..")"*) echo "$name must be outside the repository: $dir" >&2; exit 1 ;;
    esac
}

# The gateway knows the server's name; Immich's own .env doesn't need it.
SERVER_NAME=$(sed -n "s/^SERVER_NAME=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$gateway/.env")
[ -n "$SERVER_NAME" ] || { echo "SERVER_NAME missing in gateway/.env (set up the gateway first)" >&2; exit 1; }
IMMICH_HOST="immich.${SERVER_NAME#*.}"

# --- 1. .env ---------------------------------------------------------------
# Immich's container names are fixed (immich_server, ...): a second copy can't run next to one
# started from another folder.
running_from=$(sudo docker inspect immich_server \
    --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)
if [ -n "$running_from" ] && [ "$(realpath -m "$running_from")" != "$app" ]; then
    echo "Immich already runs from $running_from." >&2
    echo "Move it first (README, \"Moving an existing installation\"): copy its .env here," >&2
    echo "run 'sudo docker compose down' there, then run this script again." >&2
    exit 1
fi

if [ ! -f .env ]; then
    upload=$(ask "Photos and videos folder (UPLOAD_LOCATION; use the data disk)" "/srv/data/photos/immich" "${1:-}")
    db=$(ask "Database folder (DB_DATA_LOCATION; local disk, SSD preferred)" "/home/immich/postgres" "${2:-}")
    check_dir "Upload folder" "$upload"
    check_dir "Database folder" "$db"
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo Etc/UTC)

    echo
    echo "UPLOAD_LOCATION   $upload"
    echo "DB_DATA_LOCATION  $db"
    echo "TZ                $tz"
    echo "DB_PASSWORD       generated, stored in .env"
    read -rp "Write .env and continue? [y/N] " ok
    [[ $ok == [yY]* ]] || { echo "Nothing changed."; exit 1; }

    cp .env.example .env
    chmod 600 .env
    sed -i 's/^# TZ=.*/TZ=/' .env
    set_env UPLOAD_LOCATION "$upload"
    set_env DB_DATA_LOCATION "$db"
    set_env TZ "$tz"
    set_env DB_PASSWORD "$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9')"   # Immich: A-Za-z0-9 only
    echo "ok      .env created"
elif [ $# -gt 0 ]; then
    echo "note    .env already exists, arguments ignored (edit .env to change the folders)"
fi

set -a; . ./.env; set +a

# --- 2. client secret --------------------------------------------------------
restart_authelia=no
new_secret=
if sudo test -s "$digest_file"; then
    echo "keep    client secret (Authelia already has immich_client_digest)"
else
    out=$(sudo docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 \
        --variant sha512 --random --random.length 72 --random.charset rfc3986)
    new_secret=$(printf '%s\n' "$out" | sed -n 's/^Random Password: //p')
    digest=$(printf '%s\n' "$out" | sed -n 's/^Digest: //p')
    if [ -z "$new_secret" ] || [ -z "$digest" ]; then
        echo "FAIL    unexpected output from authelia crypto hash generate:" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf '%s' "$digest" | sudo tee "$digest_file" >/dev/null
    sudo chmod 600 "$digest_file"
    restart_authelia=yes
    echo "ok      client secret created (digest in gateway/authelia/secrets/immich_client_digest)"
fi

# --- 3. Authelia -------------------------------------------------------------
if ! grep -q '^IMMICH_HOST=' "$gateway/.env"; then
    echo "IMMICH_HOST=$IMMICH_HOST" >> "$gateway/.env"
    restart_authelia=yes
    echo "ok      IMMICH_HOST added to gateway/.env"
fi
issuer="https://$SERVER_NAME/auth/.well-known/openid-configuration"
if [ $restart_authelia = yes ]; then
    (cd "$gateway" && sudo docker compose up -d --force-recreate authelia)
    echo -n "wait    Authelia "
    for _ in $(seq 30); do
        curl -fsS --max-time 2 "$issuer" 2>/dev/null | grep -q '"issuer"' && break
        echo -n "."; sleep 2
    done
    echo
fi

# --- 4. folders, can a container reach Authelia? -----------------------------
# Only created when missing; existing folders (and their owners) are left alone. The containers
# run as root, and Postgres sets up its own folder's permissions.
for d in "$UPLOAD_LOCATION" "$DB_DATA_LOCATION"; do
    if sudo test -d "$d"; then
        echo "keep    $d"
    else
        sudo mkdir -p "$d"
        sudo chmod 750 "$d"
        echo "ok      $d created"
    fi
done

if sudo docker run --rm curlimages/curl:8.10.1 -fsS --max-time 10 "$issuer" | grep -q '"issuer"'; then
    echo "ok      containers reach $issuer"
else
    echo "FAIL    a container can't fetch $issuer"
    echo "        Is Authelia running (cd gateway && sudo docker compose logs --tail=20 authelia)?"
    echo "        If the error is about resolving the name, add extra_hosts to immich-server"
    echo "        (README, step 3) with the address $(tailscale ip -4 | head -1)."
    exit 1
fi

# --- 5. start --------------------------------------------------------------
sudo docker compose config > /dev/null
sudo docker compose up -d
echo
echo "Started. Follow the log with: sudo docker compose logs -f immich-server"
echo "Publish it in the tailnet (once):"
echo "  sudo tailscale serve --service=svc:immich --https=443 http://127.0.0.1:2283"
echo
echo "Immich OAuth settings (README, step 4):"
echo "  Issuer URL     $issuer"
echo "  Client ID      immich"
if [ -n "$new_secret" ]; then
    echo "  Client Secret  $new_secret"
    echo "  (shown only now and not stored; if lost, delete gateway/authelia/secrets/immich_client_digest"
    echo "   and run this script again)"
else
    echo "  Client Secret  unchanged (the one already in Immich's settings)"
fi
