#!/usr/bin/env bash
set -euo pipefail

echo "== JKEF Bootstrap Installer =="

need() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1"; exit 1; }; }
need curl
need tar
need grep
need sed
need find
need mktemp

# --- Ask for repo ---
read -rp "GitHub Updates-Repo [jkef80/jkef-bot-updates]: " JKEF_GH_REPO
JKEF_GH_REPO="${JKEF_GH_REPO:-jkef80/jkef-bot-updates}"

# --- Ask for token (visible prompt, hidden input) ---
echo "Bitte GitHub Token eingeben (Eingabe bleibt unsichtbar):"
read -rsp "Token: " JKEF_GH_TOKEN
echo
if [ -z "${JKEF_GH_TOKEN}" ]; then
  echo "Kein Token eingegeben – Abbruch."
  exit 1
fi

# --- Save token for later updates (system-wide secrets path) ---
sudo mkdir -p /etc/jkef-trading-bot
sudo bash -c "cat > /etc/jkef-trading-bot/github.env" <<EOF
JKEF_GH_REPO=${JKEF_GH_REPO}
JKEF_GH_TOKEN=${JKEF_GH_TOKEN}
EOF
sudo chmod 600 /etc/jkef-trading-bot/github.env

echo "GitHub-Zugang gespeichert: /etc/jkef-trading-bot/github.env (600)"

# --- Get latest release JSON ---
API_URL="https://api.github.com/repos/${JKEF_GH_REPO}/releases/latest"

echo "Hole Latest Release von GitHub …"
set +e
HTTP_CODE=$(curl -sS -o /tmp/jkef_release.json -w "%{http_code}" \
  -H "Authorization: Bearer ${JKEF_GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API_URL}")
set -e

if [ "${HTTP_CODE}" != "200" ]; then
  echo "Fehler: GitHub API HTTP ${HTTP_CODE} beim Abruf von releases/latest"
  echo "Antwort:"
  cat /tmp/jkef_release.json || true
  echo
  echo "Häufige Ursachen:"
  echo "- Token falsch/abgelaufen"
  echo "- Token hat keinen Zugriff auf das private Repo"
  echo "- Repo-Name falsch: ${JKEF_GH_REPO}"
  exit 1
fi

# --- Find asset download URL (expects jkef-trading-bot_slim_*.tar.gz) ---
ASSET_URL=$(grep -Eo '"browser_download_url":[^"]+"' /tmp/jkef_release.json \
  | sed 's/"browser_download_url":"//;s/"$//' \
  | grep -E 'jkef-trading-bot_slim_.*\.tar\.gz$' \
  | head -n1 || true)

if [ -z "${ASSET_URL}" ]; then
  echo "Kein passendes Asset gefunden."
  echo "Erwartet: jkef-trading-bot_slim_*.tar.gz"
  echo "Assets im Release waren:"
  grep -Eo '"name":[^"]+"' /tmp/jkef_release.json | head -n 50 || true
  exit 1
fi

echo "Gefundenes Asset:"
echo "  ${ASSET_URL}"

# --- Download asset (authorized) ---
WORKDIR="$(mktemp -d /tmp/jkef-install.XXXXXX)"
ARCHIVE="${WORKDIR}/bot.tar.gz"

echo "Lade Release herunter …"
curl -fL \
  -H "Authorization: Bearer ${JKEF_GH_TOKEN}" \
  -H "Accept: application/octet-stream" \
  "${ASSET_URL}" \
  -o "${ARCHIVE}"

# --- Extract ---
echo "Entpacke Release …"
tar -xzf "${ARCHIVE}" -C "${WORKDIR}"

# --- Find inner install.sh ---
INNER_INSTALL="$(find "${WORKDIR}" -maxdepth 4 -name install.sh -type f | head -n 1 || true)"
if [ -z "${INNER_INSTALL}" ]; then
  echo "Keine install.sh im Release-Archiv gefunden – Abbruch."
  echo "Inhalt (Top-Level):"
  find "${WORKDIR}" -maxdepth 2 -type f | head -n 50 || true
  exit 1
fi

chmod +x "${INNER_INSTALL}"

echo "Starte Bot-Installation aus Release:"
echo "  ${INNER_INSTALL}"

# Pass repo/token to inner install (so it can enable online updates)
export JKEF_GH_REPO
export JKEF_GH_TOKEN

exec sudo -E bash "${INNER_INSTALL}"
