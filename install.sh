#!/usr/bin/env bash
set -euo pipefail

# JKEF Installer (Bootstrap) - MENU v3 (TTY-safe for curl|sudo bash)
# INSTALL: wipes /opt/jkef-trading-bot (incl .env + data)
# UPDATE : keeps /opt/jkef-trading-bot/.env and /opt/jkef-trading-bot/data
# Token is asked once and passed to the internal installer.

REPO_DEFAULT="jkef80/jkef-bot-updates"
TARGET_DEFAULT="/opt/jkef-trading-bot"
WORK_ROOT_DEFAULT="/tmp/jkef-install"
API_BASE="https://api.github.com"

log() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_root() { [[ ${EUID:-0} -eq 0 ]] || die "Bitte mit sudo ausfuehren"; }

get_run_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then echo "$SUDO_USER"; else echo "${USER:-root}"; fi
}

get_home_dir() {
  local u="$1"; local h
  h="$(getent passwd "$u" | cut -d: -f6 || true)"
  [[ -n "$h" ]] && echo "$h" || echo "/root"
}

ensure_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || die "whiptail fehlt (kein apt-get zum Installieren vorhanden)"
  log "Installing whiptail (newt) ..."
  apt-get update -y >/dev/null
  apt-get install -y whiptail >/dev/null
}

wp_menu() {
  local title="$1"; shift
  local text="$1"; shift
  local -a items=("$@")
  local tty="/dev/tty"
  [[ -r "$tty" ]] || die "Kein TTY (/dev/tty) - bitte interaktiv ausfuehren"
  local tmp; tmp="$(mktemp)"
  whiptail --title "$title" --menu "$text" 15 90 6 "${items[@]}" 2>"$tmp" <"$tty" >"$tty" || true
  local choice; choice="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  echo "$choice"
}

wp_yesno() {
  local title="$1"; shift
  local text="$1"; shift
  local tty="/dev/tty"
  [[ -r "$tty" ]] || die "Kein TTY (/dev/tty)"
  whiptail --title "$title" --yesno "$text" 12 90 <"$tty" >"$tty" 2>&1
}

prompt_secret_tty() {
  local prompt="$1"
  local tty="/dev/tty"
  [[ -r "$tty" ]] || die "Kein TTY (/dev/tty)"
  printf "%s" "$prompt" >"$tty"
  stty -echo <"$tty"
  local val=""
  IFS= read -r val <"$tty" || true
  stty echo <"$tty"
  printf "\n" >"$tty"
  echo "$val"
}

select_asset_url() {
  python3 - <<'PY'
import json,sys
j=json.load(sys.stdin)
assets=j.get('assets') or []
for a in assets:
    name=a.get('name','')
    url=a.get('browser_download_url','')
    if name.endswith('.tar.gz') and url:
        print(url); sys.exit(0)
for a in assets:
    url=a.get('browser_download_url','')
    if url:
        print(url); sys.exit(0)
print('')
PY
}

need_root
ensure_whiptail

RUN_USER="$(get_run_user)"
HOME_DIR="$(get_home_dir "$RUN_USER")"
REPO="${JKEF_REPO:-$REPO_DEFAULT}"
TARGET="${JKEF_TARGET:-$TARGET_DEFAULT}"
WORK_ROOT="${JKEF_WORK_ROOT:-$WORK_ROOT_DEFAULT}"
CACHE_DIR="${HOME_DIR}/.cache/jkef"

mkdir -p "$WORK_ROOT" "$CACHE_DIR"
chown -R "${RUN_USER}:${RUN_USER}" "$CACHE_DIR" || true

MODE="$(wp_menu "JKEF Installer" "Bitte Aktion waehlen" \
  install "Neu installieren (loescht ${TARGET} inkl. .env + data)" \
  update  "Update (behaelt ${TARGET}/.env und ${TARGET}/data)" \
  exit    "Abbrechen")"

case "$MODE" in
  install|update) ;;
  exit|"") log "Abbruch."; exit 0 ;;
  *) die "Ungueltige Auswahl: $MODE" ;;
esac

if [[ "$MODE" == "install" ]]; then
  if ! wp_yesno "JKEF Installer" "WIRKLICH neu installieren?\n\nDas loescht:\n  ${TARGET}\ninkl. .env und data\n\nFortfahren?"; then
    log "Abbruch."; exit 0
  fi
fi

log "== JKEF Installer (Bootstrap) =="
log "Repo   : $REPO"
log "User   : $RUN_USER"
log "Home   : $HOME_DIR"
log "Target : $TARGET"
log "Cache  : $CACHE_DIR"
log "Mode   : $MODE"
echo

TOKEN="$(prompt_secret_tty "GitHub Token eingeben (Eingabe bleibt unsichtbar) und ENTER: ")"
[[ -n "$TOKEN" ]] || die "Kein Token eingegeben."

if [[ "$MODE" == "install" ]]; then
  log "Wiping target directory: $TARGET"
  rm -rf "$TARGET"
fi

TAR_PATH="${CACHE_DIR}/jkef-release.tar.gz"
EXTRACT_DIR="${WORK_ROOT}/release"
rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"

log "Fetching latest release ..."
REL_JSON="$(curl -fsSL -H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json" "${API_BASE}/repos/${REPO}/releases/latest")"
ASSET_URL="$(printf "%s" "$REL_JSON" | select_asset_url)"
[[ -n "$ASSET_URL" ]] || die "Kein Release-Asset (.tar.gz) gefunden."

log "Downloading release asset ..."
curl -fsSL -L -H "Authorization: token ${TOKEN}" -H "Accept: application/octet-stream" "$ASSET_URL" -o "$TAR_PATH"

log "Extracting ..."
tar -xzf "$TAR_PATH" -C "$EXTRACT_DIR"

INNER="$EXTRACT_DIR"
shopt -s nullglob
entries=("$EXTRACT_DIR"/*)
shopt -u nullglob
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
  INNER="${entries[0]}"
fi

[[ -f "${INNER}/install.sh" ]] || die "install.sh nicht im Release gefunden."
chmod +x "${INNER}/install.sh" || true

export JKEF_GH_TOKEN="$TOKEN"
export GH_TOKEN="$TOKEN"
export JKEF_INSTALL_MODE="$MODE"

bash "${INNER}/install.sh" < /dev/tty

log "Done."
