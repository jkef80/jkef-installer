#!/usr/bin/env bash
set -euo pipefail

echo "== JKEF Bootstrap Installer =="

need() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1"; exit 1; }; }
need curl
need tar
need grep
need sed

# --- GitHub credentials ---
read -rp "GitHub Repo [jkef80/jkef-bot-updates]: " JKEF_GH_REPO
JKEF_GH_REPO="${JKEF_GH_REPO:-jkef80/jkef-bot-updates}"

read -rsp "GitHub Token (private repo access): " JKEF_GH_TOKEN
echo
if [ -z "$JKEF_GH_TOKEN" ]; then
  echo "Kein Token eingegeben – Abbruch."
  exit 1
fi

# --- save token for runtime updates ---
sudo mkdir -p /etc/jkef-trading-bot
sudo bash -c "cat > /etc/jkef-trading-bot/github.env" <<EOF
JKEF_GH_REPO=${JKEF_GH_REPO}
JKEF_GH_TOKEN=${JKEF_GH_TOKEN}
EOF
sudo chmod 600 /etc/jkef-trading-bot/github.env

echo "GitHub-Zugang gespeichert."

# --- get latest release info ---
API_URL="https://api.github.com/repos/${JKEF_GH_REPO}/releases/latest"

echo "Hole Latest Release von GitHub …"
RELEASE_JSON=$(curl -fsSL \
  -H "Authorization: Bearer ${JKEF_GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "$API_URL")

ASSET_URL=$(echo "$RELEASE_JSON" | \
  grep -Eo '"browser_download_url":[^"]+"[^"]*jkef-trading-bot_slim_.*\.tar\.gz"' | \
  head -n1 | cut -d\" -f4)

if [ -z "$ASSET_URL" ]; then
  echo "Kein passendes Slim-Asset gefunden."
  exit 1
fi

echo "Gefundenes Asset:"
echo "$ASSET_URL"

# --- download ---
WORKDIR="/tmp/jkef-install"
mkdir -p "$WORKDIR"
ARCHIVE="$WORKDIR/bot.tar.gz"

echo "Lade Release herunter …"
curl -fL \
  -H "Authorization: Bearer ${JKEF_GH_TOKEN}" \
  "$ASSET_URL" \
  -o "$ARCHIVE"

# --- extract ---
echo "Entpacke Release …"
tar -xzf "$ARCHIVE" -C "$WORKDIR"

# --- find install.sh inside archive ---
INNER_INSTALL=$(find "$WORKDIR" -name install.sh | head -n1)
if [ -z "$INNER_INSTALL" ]; then
  echo "Keine install.sh im Release gefunden – Abbruch."
  exit 1
fi

chmod +x "$INNER_INSTALL"

echo "Starte Bot-Installation aus Release …"
exec sudo bash "$INNER_INSTALL"
