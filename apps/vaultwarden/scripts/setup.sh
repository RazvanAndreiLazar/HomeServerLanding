#!/bin/bash
# Prepares and starts Vaultwarden. Run on the server; safe to run again.
#
#   ./scripts/setup.sh [DATA_DIR]
#
#   1. creates .env from .env.example on the first run (data folder from the argument or asked for)
#   2. creates the OIDC client secret: the plain one goes into .env (Vaultwarden needs it), its
#      digest into gateway/authelia/secrets/vaultwarden_client_digest
#   3. adds VAULTWARDEN_HOST to gateway/.env and restarts Authelia if anything was new and the
#      gateway is complete (apps added in the same update each add their own part; the last one
#      restarts Authelia). Run this before restarting the gateway after an update.
#   4. creates the data folder and checks that a container can reach Authelia
#   5. starts Vaultwarden and prints the tailscale serve command
# The Tailscale Service and the first accounts are separate steps (see ../README.md).
set -euo pipefail

app="$(cd "$(dirname "$0")/.." && pwd)"
gateway="$(cd "$app/../../gateway" && pwd)"
digest_file="$gateway/authelia/secrets/vaultwarden_client_digest"
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

# Prints why Authelia can't start yet: a host missing in gateway/.env, or a client digest that
# configuration.yml refers to but that doesn't exist (from apps added in the same update).
gateway_missing() {
    local out f
    if ! out=$(cd "$gateway" && sudo docker compose config -q 2>&1); then
        printf '%s\n' "$out"; return 0
    fi
    for f in $(grep -o 'secret "/secrets/[^"]*"' "$gateway/authelia/config/configuration.yml" | sed 's|.*/secrets/||; s|"$||'); do
        sudo test -s "$gateway/authelia/secrets/$f" || { echo "gateway/authelia/secrets/$f is missing"; return 0; }
    done
    return 1
}

# --- 1. .env ---------------------------------------------------------------
if [ ! -f .env ]; then
    name=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    tailnet=${name#*.}
    data_dir=$(ask "Vaultwarden data folder (database, attachments)" "/srv/data/vaultwarden" "${1:-}")
    check_dir "Data folder" "$data_dir"

    echo
    echo "SERVER_NAME           $name"
    echo "VAULTWARDEN_HOST      vaultwarden.$tailnet"
    echo "VAULTWARDEN_DATA_DIR  $data_dir"
    read -rp "Write .env and continue? [y/N] " ok
    [[ $ok == [yY]* ]] || { echo "Nothing changed."; exit 1; }

    cp .env.example .env
    chmod 600 .env
    set_env SERVER_NAME "$name"
    set_env VAULTWARDEN_HOST "vaultwarden.$tailnet"
    set_env VAULTWARDEN_DATA_DIR "$data_dir"
    echo "ok      .env created"
elif [ $# -gt 0 ]; then
    echo "note    .env already exists, argument ignored (edit .env to change the folder)"
fi

set -a; . ./.env; set +a

# --- 2. client secret --------------------------------------------------------
restart_authelia=no
if [ -n "${VAULTWARDEN_CLIENT_SECRET:-}" ] && sudo test -s "$digest_file"; then
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
    set_env VAULTWARDEN_CLIENT_SECRET "$secret"
    VAULTWARDEN_CLIENT_SECRET=$secret
    printf '%s' "$digest" | sudo tee "$digest_file" >/dev/null
    sudo chmod 600 "$digest_file"
    restart_authelia=yes
    echo "ok      client secret created (digest in gateway/authelia/secrets/vaultwarden_client_digest)"
fi

# --- 3. Authelia -------------------------------------------------------------
if ! grep -q '^VAULTWARDEN_HOST=' "$gateway/.env"; then
    echo "VAULTWARDEN_HOST=$VAULTWARDEN_HOST" >> "$gateway/.env"
    restart_authelia=yes
    echo "ok      VAULTWARDEN_HOST added to gateway/.env"
fi
issuer="https://$SERVER_NAME/auth/.well-known/openid-configuration"
if [ $restart_authelia = yes ]; then
    if why=$(gateway_missing); then
        echo "note    Authelia not restarted yet: $why"
        echo "        Run the setup.sh of the other apps from the same update; the last one restarts"
        echo "        Authelia. Until then the Authelia login for Vaultwarden doesn't work."
    else
        (cd "$gateway" && sudo docker compose up -d --force-recreate authelia)
        echo -n "wait    Authelia "
        for _ in $(seq 30); do
            curl -fsS --max-time 2 "$issuer" 2>/dev/null | grep -q '"issuer"' && break
            echo -n "."; sleep 2
        done
        echo
    fi
fi

# --- 4. folder, can a container reach Authelia? ------------------------------
sudo mkdir -p "$VAULTWARDEN_DATA_DIR"
sudo chmod 700 "$VAULTWARDEN_DATA_DIR"
echo "ok      $VAULTWARDEN_DATA_DIR"

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
echo
echo "Started. Follow the log with: sudo docker compose logs -f"
echo "Publish it in the tailnet (once):"
echo "  sudo tailscale serve --service=svc:vaultwarden --https=443 http://127.0.0.1:8222"
