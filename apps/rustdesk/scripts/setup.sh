#!/bin/bash
# Prepares and starts the RustDesk server (hbbs + hbbr). Run on the server; safe to run again.
#
#   ./scripts/setup.sh [DATA_DIR]
#
#   1. creates .env from .env.example on the first run (data folder from the argument or asked for)
#   2. creates the data folder and checks that the ports are free
#   3. starts the relay, which creates the server's key pair on its first start, then the ID server
#   4. puts the public key into gateway/.env (RUSTDESK_KEY) and recreates Caddy, so the help page
#      https://<SERVER_NAME>/rustdesk/ shows it to logged-in family members
#   5. prints the values for the RustDesk clients
# Installing and configuring the clients is a separate step (see ../README.md).
set -euo pipefail

app="$(cd "$(dirname "$0")/.." && pwd)"
gateway="$(cd "$app/../../gateway" && pwd)"
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

SERVER_NAME=$(sed -n "s/^SERVER_NAME=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$gateway/.env")
[ -n "$SERVER_NAME" ] || { echo "SERVER_NAME missing in gateway/.env (set up the gateway first)" >&2; exit 1; }
LAN_IP=$(sed -n "s/^LAN_IP=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$gateway/.env")

# --- 1. .env ---------------------------------------------------------------
if [ ! -f .env ]; then
    data_dir=$(ask "RustDesk data folder (key pair, peer database)" "/srv/data/rustdesk" "${1:-}")
    check_dir "Data folder" "$data_dir"

    echo
    echo "RUSTDESK_DATA_DIR  $data_dir"
    read -rp "Write .env and continue? [y/N] " ok
    [[ $ok == [yY]* ]] || { echo "Nothing changed."; exit 1; }

    cp .env.example .env
    chmod 600 .env
    set_env RUSTDESK_DATA_DIR "$data_dir"
    echo "ok      .env created"
elif [ $# -gt 0 ]; then
    echo "note    .env already exists, argument ignored (edit .env to change the folder)"
fi

set -a; . ./.env; set +a

# --- 2. folder, ports ----------------------------------------------------------
sudo mkdir -p "$RUSTDESK_DATA_DIR"
sudo chmod 700 "$RUSTDESK_DATA_DIR"                  # holds the private key
echo "ok      $RUSTDESK_DATA_DIR"

if [ -z "$(sudo docker compose ps -q --status running 2>/dev/null)" ]; then
    in_use=$(sudo ss -Hlntup '( sport >= :21115 and sport <= :21117 )')
    if [ -n "$in_use" ]; then
        echo "FAIL    a RustDesk port (21115-21117) is already in use on the server:"
        printf '%s\n' "$in_use" | sed 's/^/        /'
        echo "        Stop what holds it (e.g. a RustDesk server installed without Docker), then run this again."
        exit 1
    fi
    echo "ok      ports 21115-21117 are free"
fi

# --- 3. start --------------------------------------------------------------
sudo docker compose config > /dev/null
pub_file="$RUSTDESK_DATA_DIR/id_ed25519.pub"
if ! sudo test -s "$pub_file"; then
    # Both services create a key pair when there is none; start one first so they share it.
    sudo docker compose up -d hbbr
    echo -n "wait    key pair "
    for _ in $(seq 30); do
        sudo test -s "$pub_file" && break
        echo -n "."; sleep 1
    done
    echo
    if ! sudo test -s "$pub_file"; then
        echo "FAIL    the relay didn't create $pub_file. Check: sudo docker compose logs hbbr"
        exit 1
    fi
    echo "ok      key pair created"
fi
sudo docker compose up -d
key=$(sudo cat "$pub_file")

# --- 4. key for the help page ----------------------------------------------
if [ "$(sed -n "s/^RUSTDESK_KEY=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$gateway/.env")" = "$key" ]; then
    echo "keep    RUSTDESK_KEY in gateway/.env"
else
    tmp=$(mktemp)
    grep -v '^RUSTDESK_KEY=' "$gateway/.env" > "$tmp" || true
    echo "RUSTDESK_KEY=$key" >> "$tmp"
    cat "$tmp" > "$gateway/.env"                 # cat onto the file keeps its owner and mode
    rm -f "$tmp"
    echo "ok      RUSTDESK_KEY set in gateway/.env"
    if out=$(cd "$gateway" && sudo docker compose config -q 2>&1); then
        (cd "$gateway" && sudo docker compose up -d --no-deps --force-recreate caddy)
    else
        echo "note    Caddy not restarted yet: $out"
        echo "        The help page shows the key once the gateway is complete and Caddy restarts."
    fi
fi

# --- 5. client settings ----------------------------------------------------
echo
echo "Started. Follow the log with: sudo docker compose logs -f"
echo
echo "RustDesk client settings (Settings → Network → ID/Relay server; README, step 3):"
echo "  ID server     $SERVER_NAME        (home network without Tailscale: ${LAN_IP:-<LAN_IP>})"
echo "  Relay server  (empty)"
echo "  API server    (empty)"
echo "  Key           $key"
echo "Also on https://$SERVER_NAME/rustdesk/ for logged-in family members."
