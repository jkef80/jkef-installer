#!/usr/bin/env bash
set -euo pipefail

APP_NAME="JKEF Bootstrap Installer"
DEFAULT_REPO="jkef80/jkef-bot-updates"

CFG_DIR="/etc/jkef-trading-bot"
GH_ENV="${CFG_DIR}/github.env"
INSTALL_DIR="/opt/jkef-trading-bot"
APP_SERVICE="jkef-trading-bot"
BACKUP_DIR_DEFAULT="/var/lib/jkef-trading-bot/backups"

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

ensure_service_dropin_envfile() {
  local envfile="$1"
  local dropin_dir="/etc/systemd/system/${APP_SERVICE}.service.d"
  local dropin_file="${dropin_dir}/override.conf"
  run_root mkdir -p "$dropin_dir"
  run_root bash -c "cat > '$dropin_file' <<EOF2
[Service]
EnvironmentFile=-${envfile}
EOF2"
}

ensure_backup_dir_and_env() {
  # Detect service user (may be empty => root)
  local svc_user
  svc_user="$(run_root systemctl show -p User --value "${APP_SERVICE}" 2>/dev/null || true)"
  svc_user="${svc_user:-root}"

  # Create backup dir
  run_root mkdir -p "$BACKUP_DIR_DEFAULT"
  run_root chown -R "${svc_user}:${svc_user}" "$(dirname "$BACKUP_DIR_DEFAULT")"
  run_root chmod 700 "$BACKUP_DIR_DEFAULT"

  # Ensure .env has JKEF_BACKUP_DIR (do NOT overwrite user config)
  local env_file="${INSTALL_DIR}/.env"
  if [ -f "$env_file" ]; then
    if ! run_root grep -q '^JKEF_BACKUP_DIR=' "$env_file"; then
      run_root bash -c "echo 'JKEF_BACKUP_DIR=${BACKUP_DIR_DEFAULT}' >> '$env_file'"
    fi
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
cat >"$TMP" <<EOF2
# JKEF GitHub access (private repo)
JKEF_GH_REPO=${JKEF_GH_REPO}
JKEF_GH_TOKEN=${JKEF_GH_TOKEN}
EOF2

run_root bash -c "cat '$TMP' > '$GH_ENV'"
run_root chmod 600 "$GH_ENV"
run_root chown root:root "$GH_ENV" || true
rm -f "$TMP"

# Make sure the service will SEE these env vars (no post steps needed)
ensure_service_dropin_envfile "$GH_ENV"

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

# Clean target dir
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

# Ensure inner installer reads from tty (curl|bash safety)
run_root bash -c "set -a; . '$GH_ENV'; set +a; exec bash '${INSTALL_DIR}/install.sh' < /dev/tty > /dev/tty 2>&1"

# After inner install: ensure backup dir exists + env present
ensure_backup_dir_and_env

# Reload systemd state and restart to pick up env drop-in
run_root systemctl daemon-reload || true
run_root systemctl restart "$APP_SERVICE" || true

rm -rf "$TMPDIR"

say ""
say "Fertig."
say "Wenn der Service läuft: systemctl status ${APP_SERVICE}"
