#!/usr/bin/env bash
set -euo pipefail

APP_NAME="JKEF Bootstrap Installer"
DEFAULT_REPO="jkef80/jkef-bot-updates"

CFG_DIR="/etc/jkef-trading-bot"
GH_ENV="${CFG_DIR}/github.env"
INSTALL_DIR="/opt/jkef-trading-bot"

TTY="/dev/tty"
if [ ! -e "$TTY" ]; then
  TTY="/dev/stdin"
fi

say() { echo -e "$*" >"$TTY"; }
die() { say "Fehler: $*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

run_root() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

apt_install_if_missing() {
  local pkg="$1" cmd="$2"
  if ! need_cmd "$cmd"; then
    say "Installiere Paket: $pkg …"
    run_root apt-get update -y
    run_root apt-get install -y "$pkg"
  fi
}

say "== ${APP_NAME} =="

apt_install_if_missing "curl" "curl"
apt_install_if_missing "jq" "jq"
apt_install_if_missing "tar" "tar"
apt_install_if_missing "ca-certificates" "update-ca-certificates" || true

run_root mkdir -p "$CFG_DIR"
run_root chmod 700 "$CFG_DIR"

say ""
say "GitHub Updates-Repo [${DEFAULT_REPO}]: "
read -r JKEF_GH_REPO <"$TTY" || true
JKEF_GH_REPO="${JKEF_GH_REPO:-$DEFAULT_REPO}"

say ""
say "============================================================"
say "Gib jetzt deinen GitHub Token ein (Eingabe bleibt unsichtbar)."
say "WICHTIG: Danach ENTER drücken."
say "============================================================"
read -rsp "Token: " JKEF_GH_TOKEN <"$TTY" || true
echo "" >"$TTY"

if [ -z "${JKEF_GH_TOKEN:-}" ]; then
  die "Kein Token eingegeben – Abbruch."
fi

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

say "Hole Latest Release von GitHub …"
API_LATEST="https://api.github.com/repos/${JKEF_GH_REPO}/releases/latest"

RELEASE_JSON="$(curl -fsS \
  -H "Authorization: token ${JKEF_GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "$API_LATEST" || true)"

if [ -z "$RELEASE_JSON" ]; then
  die "Leere Antwort von GitHub API. (Token/Netzwerk?)"
fi

API_MSG="$(echo "$RELEASE_JSON" | jq -r '.message // empty' 2>/dev/null || true)"
API_STATUS="$(echo "$RELEASE_JSON" | jq -r '.status // empty' 2>/dev/null || true)"
if [ -n "$API_MSG" ]; then
  say "Fehler: GitHub API Antwort:"
  echo "$RELEASE_JSON" | jq . >"$TTY" || true
  die "GitHub API Fehler${API_STATUS:+ (Status $API_STATUS)}: $API_MSG"
fi

TAG_NAME="$(echo "$RELEASE_JSON" | jq -r '.tag_name // empty')"

# Pick asset by name pattern
ASSET_NAME="$(echo "$RELEASE_JSON" | jq -r '.assets[].name' \
  | grep -E '^jkef-trading-bot_slim_.*\.tar\.gz$' \
  | head -n 1 || true)"

if [ -z "$ASSET_NAME" ]; then
  say "Kein passendes Asset gefunden."
  say "Erwartet: jkef-trading-bot_slim_*.tar.gz"
  say "Assets im Release sind:"
  echo "$RELEASE_JSON" | jq -r '.assets[].name' >"$TTY" || true
  exit 1
fi

ASSET_ID="$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name=="'"$ASSET_NAME"'") | .id')"
if [ -z "$ASSET_ID" ] || [ "$ASSET_ID" = "null" ]; then
  die "Konnte Asset-ID nicht ermitteln."
fi

say "Gefundenes Release: ${TAG_NAME:-<unbekannt>}"
say "Gefundenes Asset:   ${ASSET_NAME}"
say "Download (via Asset-ID) …"

TMPDIR="$(mktemp -d)"
ARCHIVE="${TMPDIR}/${ASSET_NAME}"

# IMPORTANT: Download private release asset via API assets endpoint
ASSET_API="https://api.github.com/repos/${JKEF_GH_REPO}/releases/assets/${ASSET_ID}"

curl -fL \
  -H "Authorization: token ${JKEF_GH_TOKEN}" \
  -H "Accept: application/octet-stream" \
  -o "$ARCHIVE" \
  "$ASSET_API"

if [ ! -s "$ARCHIVE" ]; then
  rm -rf "$TMPDIR"
  die "Download fehlgeschlagen oder Datei ist leer."
fi

say "Entpacke nach ${INSTALL_DIR} …"
run_root mkdir -p "$INSTALL_DIR"

# clean target (optional)
run_root bash -c "find '$INSTALL_DIR' -mindepth 1 -maxdepth 1 -exec rm -rf {} +"

run_root tar -xzf "$ARCHIVE" -C "$INSTALL_DIR" --strip-components=1

if [ ! -f "${INSTALL_DIR}/install.sh" ]; then
  rm -rf "$TMPDIR"
  die "Im Paket fehlt ${INSTALL_DIR}/install.sh – Release ist nicht installierbar."
fi

run_root chmod +x "${INSTALL_DIR}/install.sh" || true

say "Starte Bot-Installer aus ${INSTALL_DIR}/install.sh …"
say "Hinweis: Ab jetzt kommen die Abfragen für .env / config.json / Binance Keys etc."
say ""

run_root bash -c "set -a; . '$GH_ENV'; set +a; bash '${INSTALL_DIR}/install.sh'"

rm -rf "$TMPDIR"

say ""
say "Fertig."
say "Wenn der Service läuft: systemctl status jkef-trading-bot"
