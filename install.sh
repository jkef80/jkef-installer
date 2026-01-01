#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# JKEF Bootstrap Installer (public repo)
# - asks for GitHub repo + token via /dev/tty (works with curl|bash)
# - stores credentials in /etc/jkef-trading-bot/github.env (600)
# - downloads latest release from private repo (assets)
# - extracts to /opt/jkef-trading-bot
# - runs /opt/jkef-trading-bot/install.sh (the real bot installer)
# ============================================================

APP_NAME="JKEF Bootstrap Installer"
DEFAULT_REPO="jkef80/jkef-bot-updates"

CFG_DIR="/etc/jkef-trading-bot"
GH_ENV="${CFG_DIR}/github.env"
INSTALL_DIR="/opt/jkef-trading-bot"

# ---- helpers ----
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

run_root() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

# Prefer /dev/tty for prompts when script is piped
TTY="/dev/tty"
if [ ! -e "$TTY" ]; then
  TTY="/dev/stdin"
fi

say() { echo -e "$*" >"$TTY"; }
die() { say "Fehler: $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

apt_install_if_missing() {
  local pkg="$1" cmd="$2"
  if ! need_cmd "$cmd"; then
    say "Installiere Paket: $pkg …"
    run_root apt-get update -y
    run_root apt-get install -y "$pkg"
  fi
}

# ---- start ----
say "== ${APP_NAME} =="

# Basic deps
apt_install_if_missing "curl" "curl"
apt_install_if_missing "jq" "jq"
apt_install_if_missing "ca-certificates" "update-ca-certificates" || true
apt_install_if_missing "tar" "tar"

# Create config dir
run_root mkdir -p "$CFG_DIR"
run_root chmod 700 "$CFG_DIR"

# Prompt repo
say ""
say "GitHub Updates-Repo [${DEFAULT_REPO}]: "
read -r JKEF_GH_REPO <"$TTY" || true
JKEF_GH_REPO="${JKEF_GH_REPO:-$DEFAULT_REPO}"

# Prompt token (hidden) - MUST read from TTY
say ""
say "============================================================"
say "Gib jetzt deinen GitHub Token ein (Eingabe bleibt unsichtbar)."
say "WICHTIG: Danach ENTER drücken."
say "============================================================"
# read -s from tty:
# shellcheck disable=SC2162
read -rsp "Token: " JKEF_GH_TOKEN <"$TTY" || true
echo "" >"$TTY"

if [ -z "${JKEF_GH_TOKEN:-}" ]; then
  die "Kein Token eingegeben – Abbruch."
fi

# Store token + repo
# We store as KEY=VALUE lines, source-able.
TMP="$(mktemp)"
cat >"$TMP" <<EOF
# JKEF GitHub access (private repo)
JKEF_GH_REPO=${JKEF_GH_REPO}
JKEF_GH_TOKEN=${JKEF_GH_TOKEN}
EOF

run_root bash -c "cat '$TMP' > '$GH_ENV'"
run_root chmod 600 "$GH_ENV"
run_root chown root:root "$GH_ENV" || true
rm -f "$TMP"

say "GitHub-Zugang gespeichert: ${GH_ENV} (600)"

# Fetch latest release JSON
say "Hole Latest Release von GitHub …"
API_URL="https://api.github.com/repos/${JKEF_GH_REPO}/releases/latest"

RELEASE_JSON="$(curl -sS \
  -H "Authorization: token ${JKEF_GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "$API_URL" || true)"

# Handle auth / API errors
if [ -z "$RELEASE_JSON" ]; then
  die "Leere Antwort von GitHub API. (Token/Netzwerk?)"
fi

API_MSG="$(echo "$RELEASE_JSON" | jq -r '.message // empty' 2>/dev/null || true)"
API_STATUS="$(echo "$RELEASE_JSON" | jq -r '.status // empty' 2>/dev/null || true)"

if [ -n "$API_MSG" ]; then
  say "Fehler: GitHub API Antwort:"
  echo "$RELEASE_JSON" | jq . >"$TTY" || true
  say ""
  die "GitHub API Fehler${API_STATUS:+ (Status $API_STATUS)}: $API_MSG"
fi

# Find asset name in assets[].name
ASSET_NAME="$(echo "$RELEASE_JSON" | jq -r '.assets[].name' | grep -E '^jkef-trading-bot_slim_.*\.tar\.gz$' | head -n 1 || true)"
if [ -z "$ASSET_NAME" ]; then
  say "Kein passendes Asset gefunden."
  say "Erwartet: jkef-trading-bot_slim_*.tar.gz"
  say "Assets im Release sind:"
  echo "$RELEASE_JSON" | jq -r '.assets[].name' >"$TTY" || true
  exit 1
fi

ASSET_URL="$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name=="'"$ASSET_NAME"'") | .browser_download_url')"
if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
  die "Konnte Download-URL für Asset nicht ermitteln."
fi

TAG_NAME="$(echo "$RELEASE_JSON" | jq -r '.tag_name // empty')"
say "Gefundenes Release: ${TAG_NAME:-<unbekannt>}"
say "Gefundenes Asset:   ${ASSET_NAME}"
say "Download …"

TMPDIR="$(mktemp -d)"
ARCHIVE="${TMPDIR}/${ASSET_NAME}"

curl -fL \
  -H "Authorization: token ${JKEF_GH_TOKEN}" \
  -H "Accept: application/octet-stream" \
  -o "$ARCHIVE" \
  "$ASSET_URL"

if [ ! -s "$ARCHIVE" ]; then
  rm -rf "$TMPDIR"
  die "Download fehlgeschlagen oder Datei ist leer."
fi

# Extract to /opt/jkef-trading-bot
say "Entpacke nach ${INSTALL_DIR} …"
run_root mkdir -p "$INSTALL_DIR"

# Clean target dir but keep it present (optional: comment out if you want preserve)
run_root bash -c "find '$INSTALL_DIR' -mindepth 1 -maxdepth 1 -exec rm -rf {} +"

run_root tar -xzf "$ARCHIVE" -C "$INSTALL_DIR" --strip-components=1

# Ensure bot installer exists
if [ ! -f "${INSTALL_DIR}/install.sh" ]; then
  rm -rf "$TMPDIR"
  die "Im Paket fehlt ${INSTALL_DIR}/install.sh – das Release ist nicht installierbar."
fi

run_root chmod +x "${INSTALL_DIR}/install.sh" || true

# Run the real installer from the package
say "Starte Bot-Installer aus ${INSTALL_DIR}/install.sh …"
say "Hinweis: Ab jetzt kommen die Abfragen für .env / config.json / Binance Keys etc."
say ""

# Export GH env for the installer/updater if it wants it
# (installer can read /etc/jkef-trading-bot/github.env anyway)
run_root bash -c "set -a; . '$GH_ENV'; set +a; bash '${INSTALL_DIR}/install.sh'"

rm -rf "$TMPDIR"

say ""
say "Fertig."
say "Wenn der Service läuft: systemctl status jkef-trading-bot"
