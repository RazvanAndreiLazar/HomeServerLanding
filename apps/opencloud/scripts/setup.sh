#!/bin/bash
# Prepares and starts OpenCloud. Run on the server; safe to run again.
#
#   ./scripts/setup.sh [CONFIG_DIR] [DATA_DIR]
#
#   1. creates .env from .env.example on the first run. Folders come from the arguments or are
#      asked for; the admin password is asked for (hidden; empty = generate one) or taken from
#      the OC_ADMIN_PASSWORD environment variable
#   2. creates the config and data folders with the right owner
#   3. checks that a container can reach Authelia's OpenID Connect discovery
#   4. starts OpenCloud and prints the tailscale serve command
# Authelia's clients and the Tailscale Service are separate steps (see ../README.md).
set -euo pipefail

app="$(cd "$(dirname "$0")/.." && pwd)"
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
        "$(realpath -m "$app/..")"*) echo "$name must be outside the repository (it holds secrets/data): $dir" >&2; exit 1 ;;
    esac
}

# --- 1. .env ---------------------------------------------------------------
if [ ! -f .env ]; then
    name=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    tailnet=${name#*.}
    config_dir=$(ask "OpenCloud config folder (generated secrets)" "/srv/opencloud/config" "${1:-}")
    data_dir=$(ask "OpenCloud data folder (users' files; use the data disk)" "/mnt/data/opencloud" "${2:-}")
    check_dir "Config folder" "$config_dir"
    check_dir "Data folder" "$data_dir"

    password=${OC_ADMIN_PASSWORD:-}
    if [ -z "$password" ]; then
        read -rsp "Password for OpenCloud's built-in admin account (empty = generate): " password; echo
    fi
    generated=no
    if [ -z "$password" ]; then
        password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')
        generated=yes
    fi
    if [[ $password == *"'"* ]]; then echo "The password must not contain a single quote" >&2; exit 1; fi

    echo
    echo "SERVER_NAME           $name"
    echo "OPENCLOUD_HOST        opencloud.$tailnet"
    echo "OPENCLOUD_CONFIG_DIR  $config_dir"
    echo "OPENCLOUD_DATA_DIR    $data_dir"
    echo "OC_UID_GID            $(id -u):$(id -g)"
    echo "OC_ADMIN_PASSWORD     $([ $generated = yes ] && echo "generated, stored in .env" || echo "as entered")"
    read -rp "Write .env and continue? [y/N] " ok
    [[ $ok == [yY]* ]] || { echo "Nothing changed."; exit 1; }

    cp .env.example .env
    chmod 600 .env
    set_env SERVER_NAME "$name"
    set_env OPENCLOUD_HOST "opencloud.$tailnet"
    set_env OPENCLOUD_CONFIG_DIR "$config_dir"
    set_env OPENCLOUD_DATA_DIR "$data_dir"
    set_env OC_UID_GID "$(id -u):$(id -g)"
    set_env OC_ADMIN_PASSWORD "$password"
    echo "ok      .env created"
elif [ $# -gt 0 ]; then
    echo "note    .env already exists, arguments ignored (edit .env to change the folders)"
fi

set -a; . ./.env; set +a

# --- 2. folders ------------------------------------------------------------
for d in "$OPENCLOUD_CONFIG_DIR" "$OPENCLOUD_DATA_DIR"; do
    sudo mkdir -p "$d"
    sudo chown "$OC_UID_GID" "$d"
    sudo chmod 750 "$d"
    echo "ok      $d"
done

# --- 3. can a container reach Authelia? ------------------------------------
issuer="https://$SERVER_NAME/auth/.well-known/openid-configuration"
if sudo docker run --rm curlimages/curl:8.10.1 -fsS --max-time 10 "$issuer" | grep -q '"issuer"'; then
    echo "ok      containers reach $issuer"
else
    echo "FAIL    a container can't fetch $issuer"
    echo "        Is the gateway running? If the error is about resolving the name, set"
    echo "        SERVER_TAILSCALE_IP=$(tailscale ip -4 | head -1) in .env and uncomment extra_hosts in docker-compose.yml."
    exit 1
fi

# --- 4. start --------------------------------------------------------------
sudo docker compose config > /dev/null
sudo docker compose up -d
echo
echo "Started. Follow the log with: sudo docker compose logs -f opencloud"
echo "Publish it in the tailnet (once):"
echo "  sudo tailscale serve --service=svc:opencloud --https=443 http://127.0.0.1:9200"
