#!/bin/bash
# Creates Authelia's secrets in gateway/authelia/secrets. Run on the server, from anywhere.
# Existing files are kept, so running it again never replaces live keys.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)/authelia/secrets"
sudo mkdir -p "$dir"

for s in jwt session storage oidc_hmac; do
    if sudo test -e "$dir/$s"; then
        echo "keep    $s"
    else
        openssl rand -hex 64 | sudo tee "$dir/$s" >/dev/null
        echo "created $s"
    fi
done

if sudo test -e "$dir/oidc_jwks.pem"; then
    echo "keep    oidc_jwks.pem"
else
    sudo openssl genrsa -out "$dir/oidc_jwks.pem" 2048 2>/dev/null
    echo "created oidc_jwks.pem"
fi

sudo chmod 700 "$dir"
sudo chmod 600 "$dir"/*

cat <<'EOF'

Each single sign-on app (OIDC client) also needs a client secret. Generate one with:

  sudo docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 \
    --variant sha512 --random --random.length 72 --random.charset rfc3986

The "Random Password" goes into the app's settings; save the "Digest" as
authelia/secrets/<app>_client_digest (see apps/<app>/README.md).
EOF
