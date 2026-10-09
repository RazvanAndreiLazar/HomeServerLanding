#!/bin/bash
# Prepares and starts AdGuard Home behind oauth2-proxy. Run on the server; safe to run again.
#
#   ./scripts/setup.sh [DATA_DIR]
#
#   1. creates .env from .env.example on the first run (data folder from the argument or asked for,
#      cookie secret generated)
#   2. creates the OIDC client secret: the plain one goes into .env, its digest into
#      gateway/authelia/secrets/adguard_client_digest
#   3. adds ADGUARD_HOST to gateway/.env and restarts Authelia if anything was new. Authelia refuses
#      to start without the digest file, so run this before restarting the gateway after an update.
#   4. creates the data folders, checks that port 53 is free and that a container can reach Authelia
#   5. starts AdGuard and oauth2-proxy
#   6. on the first run: completes AdGuard's setup wizard through its API (web interface on port
#      3000, DNS on port 53) and removes the wizard's user, so oauth2-proxy is the only login
# The Tailscale Service, AdGuard's settings and pointing devices at it are separate steps (see ../README.md).
set -euo pipefail

app="$(cd "$(dirname "$0")/.." && pwd)"
gateway="$(cd "$app/../../gateway" && pwd)"
digest_file="$gateway/authelia/secrets/adguard_client_digest"
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

# --- 1. .env ---------------------------------------------------------------
if [ ! -f .env ]; then
    name=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    tailnet=${name#*.}
    data_dir=$(ask "AdGuard data folder (settings, query log)" "/srv/data/adguard" "${1:-}")
    check_dir "Data folder" "$data_dir"

    echo
    echo "SERVER_NAME       $name"
    echo "ADGUARD_HOST      adguard.$tailnet"
    echo "ADGUARD_DATA_DIR  $data_dir"
    read -rp "Write .env and continue? [y/N] " ok
    [[ $ok == [yY]* ]] || { echo "Nothing changed."; exit 1; }

    cp .env.example .env
    chmod 600 .env
    set_env SERVER_NAME "$name"
    set_env ADGUARD_HOST "adguard.$tailnet"
    set_env ADGUARD_DATA_DIR "$data_dir"
    set_env ADGUARD_COOKIE_SECRET "$(openssl rand -base64 32 | tr -- '+/' '-_')"
    echo "ok      .env created"
elif [ $# -gt 0 ]; then
    echo "note    .env already exists, argument ignored (edit .env to change the folder)"
fi

set -a; . ./.env; set +a

# --- 2. client secret --------------------------------------------------------
restart_authelia=no
if [ -n "${ADGUARD_CLIENT_SECRET:-}" ] && sudo test -s "$digest_file"; then
    echo "keep    client secret"
else
    out=$(sudo docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 \
        --variant sha512 --random --random.length 72 --random.charset rfc3986)
    secret=$(printf '%s\n' "$out" | sed -n 's/^Random Password: //p')
    digest=$(printf '%s\n' "$out" | sed -n 's/^Digest: //p')
    if [ -z "$secret" ] || [ -z "$digest" ] || [[ $secret == *"'"* ]]; then
        echo "FAIL    unexpected output from authelia crypto hash generate:" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    set_env ADGUARD_CLIENT_SECRET "$secret"
    ADGUARD_CLIENT_SECRET=$secret
    printf '%s' "$digest" | sudo tee "$digest_file" >/dev/null
    sudo chmod 600 "$digest_file"
    restart_authelia=yes
    echo "ok      client secret created (digest in gateway/authelia/secrets/adguard_client_digest)"
fi

# --- 3. Authelia -------------------------------------------------------------
if ! grep -q '^ADGUARD_HOST=' "$gateway/.env"; then
    echo "ADGUARD_HOST=$ADGUARD_HOST" >> "$gateway/.env"
    restart_authelia=yes
    echo "ok      ADGUARD_HOST added to gateway/.env"
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

# --- 4. folders, port 53, can a container reach Authelia? --------------------
sudo mkdir -p "$ADGUARD_DATA_DIR/work" "$ADGUARD_DATA_DIR/conf"
sudo chmod 750 "$ADGUARD_DATA_DIR"
echo "ok      $ADGUARD_DATA_DIR"

if [ -z "$(sudo docker compose ps -q --status running adguard 2>/dev/null)" ]; then
    in_use=$(sudo ss -Hlntup 'sport = :53')
    if [ -n "$in_use" ]; then
        echo "FAIL    port 53 is already in use on the server:"
        printf '%s\n' "$in_use" | sed 's/^/        /'
        echo "        systemd-resolved: set DNSStubListener=no in /etc/systemd/resolved.conf, then"
        echo "        sudo systemctl restart systemd-resolved. dnsmasq (e.g. from libvirt): stop it or"
        echo "        bind it to its own interface only. Then run this script again."
        exit 1
    fi
    echo "ok      port 53 is free"
fi

if sudo docker run --rm curlimages/curl:8.10.1 -fsS --max-time 10 "$issuer" | grep -q '"issuer"'; then
    echo "ok      containers reach $issuer"
else
    echo "FAIL    a container can't fetch $issuer"
    echo "        Is Authelia running (cd gateway && sudo docker compose logs --tail=20 authelia)?"
    echo "        If the error is about resolving the name, set"
    echo "        SERVER_TAILSCALE_IP=$(tailscale ip -4 | head -1) in .env and uncomment extra_hosts in docker-compose.yml."
    exit 1
fi

# --- 5. start --------------------------------------------------------------
sudo docker compose config > /dev/null
sudo docker compose up -d

# --- 6. first run: AdGuard's setup wizard, then its login off ----------------
conf_file="$ADGUARD_DATA_DIR/conf/AdGuardHome.yaml"
if ! sudo test -s "$conf_file"; then
    # The wizard's API is only reachable on the compose network (port 3000 is not published).
    net=$(sudo docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' \
        "$(sudo docker compose ps -q adguard)")
    agh() { sudo docker run --rm --network "$net" curlimages/curl:8.10.1 "$@"; }

    echo -n "wait    AdGuard setup wizard "
    ready=no
    for _ in $(seq 30); do
        if agh -fsS --max-time 2 http://adguard:3000/control/install/get_addresses >/dev/null 2>&1; then
            ready=yes; break
        fi
        echo -n "."; sleep 2
    done
    echo
    if [ $ready = no ]; then
        echo "FAIL    AdGuard's setup wizard doesn't answer. Check: sudo docker compose logs adguard"
        exit 1
    fi

    # The wizard requires a user. It is removed right after, so its password is thrown away.
    password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')
    agh -fsS --max-time 30 -X POST -H 'Content-Type: application/json' \
        -d '{"web":{"ip":"0.0.0.0","port":3000},"dns":{"ip":"0.0.0.0","port":53},"username":"admin","password":"'"$password"'"}' \
        http://adguard:3000/control/install/configure >/dev/null
    for _ in $(seq 15); do
        sudo test -s "$conf_file" && break
        sleep 1
    done
    if ! sudo test -s "$conf_file"; then
        echo "FAIL    AdGuard didn't write $conf_file. Check: sudo docker compose logs adguard"
        exit 1
    fi
    echo "ok      AdGuard set up (web interface on port 3000, DNS on port 53)"

    # No users = no login in AdGuard; oauth2-proxy (admins only) is the login.
    sudo docker compose stop adguard
    tmp=$(sudo mktemp)
    sudo awk '
        /^users:/ { print "users: []"; skip = 1; next }
        skip && /^[ -]/ { next }
        { skip = 0; print }
    ' "$conf_file" | sudo tee "$tmp" >/dev/null
    sudo cp "$tmp" "$conf_file"           # cp onto the file keeps its owner and mode
    sudo rm -f "$tmp"
    if ! sudo grep -qx 'users: \[\]' "$conf_file"; then
        echo "FAIL    couldn't remove the wizard's user from $conf_file."
        echo "        Edit it by hand: replace the users: block with users: [] and start AdGuard again."
        exit 1
    fi
    sudo docker compose up -d adguard
    echo "ok      AdGuard's own login is off (users: [] in AdGuardHome.yaml)"
elif ! sudo grep -qx 'users: \[\]' "$conf_file"; then
    echo "note    AdGuard's own login is on (users: in $conf_file), so admins log in twice"
fi

echo
echo "Started. Follow the log with: sudo docker compose logs -f"
echo "Publish the web interface in the tailnet (once):"
echo "  sudo tailscale serve --service=svc:adguard --https=443 http://127.0.0.1:4182"
echo "Then test DNS before pointing any device at it (see README, step 5)."
