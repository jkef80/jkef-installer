#!/usr/bin/env bash
set -euo pipefail

# JKEF Installer (Bootstrap) - AUTO + MENU (TTY-safe)
# - Detects existing install in /opt/jkef-trading-bot
# - If installed: default UPDATE (keeps .env + data)
# - If not installed: default INSTALL (asks token, creates target)
# - Menu is optional; supports arrow keys + hotkeys (i/u/e)
#
# Usage:
#   sudo bash install.sh              # auto-detect + interactive menu (if TTY)
#   sudo bash install.sh --update     # force update
#   sudo bash install.sh --install    # force install (wipe target)
#
# Env overrides:
#   JKEF_REPO, JKEF_TARGET, JKEF_WORK_ROOT
#   JKEF_INSTALL_MODE=install|update
#   JKEF_GH_TOKEN / GH_TOKEN (optional to avoid prompt)

REPO_DEFAULT="jkef80/jkef-bot-updates"
TARGET_DEFAULT="/opt/jkef-trading-bot"
WORK_ROOT_DEFAULT="/tmp/jkef-install"
API_BASE="https://api.github.com"

log() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_root() { [[ ${EUID:-0} -eq 0 ]] || die "Bitte mit sudo ausfuehren"; }

has_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

# ncurses/whiptail arrow keys often fail if TERM is dumb/unknown
fix_term() {
  if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
    export TERM="xterm"
  fi
}

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
  has_tty || die "Kein TTY (/dev/tty) - bitte interaktiv ausfuehren"

  # whiptail returns selection on stderr (2>) when using --menu
  local tmp; tmp="$(mktemp)"
  # NOTE: HOTKEYS: in whiptail menu you can press first letter of tag
  whiptail --title "$title" --menu "$text" 16 92 7 "${items[@]}" 2>"$tmp" <"$tty" >"$tty" || true
  local choice; choice="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  echo "$choice"
}

wp_yesno() {
  local title="$1"; shift
  local text="$1"; shift
  local tty="/dev/tty"
  has_tty || die "Kein TTY (/dev/tty)"
  whiptail --title "$title" --yesno "$text" 12 92 <"$tty" >"$tty" 2>&1
}

prompt_secret_tty() {
  local prompt="$1"
  local tty="/dev/tty"
  has_tty || die "Kein TTY (/dev/tty)"
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
# Prefer .tar.gz asset (your custom packaged tar)
for a in assets:
    name=a.get('name','')
    url=a.get('browser_download_url','')
    if name.endswith('.tar.gz') and url:
        print(url); sys.exit(0)
# Fallback: any asset
for a in assets:
    url=a.get('browser_download_url','')
    if url:
        print(url); sys.exit(0)
print('')
PY
}

# ---------------- main ----------------
need_root
fix_term

RUN_USER="$(get_run_user)"
HOME_DIR="$(get_home_dir "$RUN_USER")"
REPO="${JKEF_REPO:-$REPO_DEFAULT}"
TARGET="${JKEF_TARGET:-$TARGET_DEFAULT}"
WORK_ROOT="${JKEF_WORK_ROOT:-$WORK_ROOT_DEFAULT}"
CACHE_DIR="${HOME_DIR}/.cache/jkef"

mkdir -p "$WORK_ROOT" "$CACHE_DIR"
chown -R "${RUN_USER}:${RUN_USER}" "$CACHE_DIR" || true

INSTALLED="no"
if [[ -d "$TARGET" ]]; then
  # if folder exists, treat as installed (even if .env missing)
  INSTALLED="yes"
fi

# parse args / env
MODE="${JKEF_INSTALL_MODE:-}"
case "${1:-}" in
  --install) MODE="install" ;;
  --update)  MODE="update" ;;
  "" ) : ;;
  * ) die "Unbekannter Parameter: ${1}. Nutze: --install | --update" ;;
esac

# default mode by detection
if [[ -z "$MODE" ]]; then
  if [[ "$INSTALLED" == "yes" ]]; then MODE="update"; else MODE="install"; fi
fi

# Show menu only if TTY and user didn't force mode with args/env
FORCED="no"
if [[ -n "${JKEF_INSTALL_MODE:-}" || "${1:-}" == "--install" || "${1:-}" == "--update" ]]; then
  FORCED="yes"
fi

if [[ "$FORCED" == "no" && "$(has_tty && echo yes || echo no)" == "yes" ]]; then
  ensure_whiptail

  local_info="Erkannt: "
  if [[ "$INSTALLED" == "yes" ]]; then
    local_info+="INSTALLIERT (Default: UPDATE)"
  else
    local_info+="NICHT installiert (Default: INSTALL)"
  fi

  # Note: You can select with arrow keys OR press i/u/e then Enter
  CHOICE="$(wp_menu "JKEF Installer" \
    "Bitte Aktion waehlen\n\n${local_info}\n\nTipps: Pfeil hoch/runter ODER Taste i/u/e, TAB fuer <Ok>, ENTER." \
    install "Neu installieren (loescht ${TARGET} inkl. .env + data)" \
    update  "Update (behaelt ${TARGET}/.env und ${TARGET}/data)" \
    exit    "Abbrechen")"

  case "$CHOICE" in
    install|update) MODE="$CHOICE" ;;
    exit|"") log "Abbruch."; exit 0 ;;
    *) die "Ungueltige Auswahl: $CHOICE" ;;
  esac
fi

if [[ "$MODE" == "install" ]]; then
  if has_tty; then
    ensure_whiptail || true
    if command -v whiptail >/dev/null 2>&1; then
      if ! wp_yesno "JKEF Installer" "WIRKLICH neu installieren?\n\nDas loescht:\n  ${TARGET}\ninkl. .env und data\n\nFortfahren?"; then
        log "Abbruch."; exit 0
      fi
    else
      log "WARN: whiptail nicht verfuegbar, fahre ohne Rueckfrage fort (INSTALL)."
    fi
  fi
fi

log "== JKEF Installer (Bootstrap) =="
log "Repo     : $REPO"
log "User     : $RUN_USER"
log "Home     : $HOME_DIR"
log "Target   : $TARGET"
log "Cache    : $CACHE_DIR"
log "Mode     : $MODE"
log "Installed: $INSTALLED"
echo

# Token handling:
# - For UPDATE: token optional (if release is public, it might work without)
# - For INSTALL: token required (as you want "install nur mit KEY")
TOKEN="${JKEF_GH_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  if [[ "$MODE" == "install" ]]; then
    has_tty || die "Kein TTY fuer Token-Eingabe. Setze JKEF_GH_TOKEN oder GH_TOKEN als Env."
    TOKEN="$(prompt_secret_tty "GitHub Token eingeben (Eingabe bleibt unsichtbar) und ENTER: ")"
    [[ -n "$TOKEN" ]] || die "Kein Token eingegeben."
  else
    # update: try without token first; if fails, we will ask later
    TOKEN=""
  fi
fi

if [[ "$MODE" == "install" ]]; then
  log "Wiping target directory: $TARGET"
  rm -rf "$TARGET"
fi

TAR_PATH="${CACHE_DIR}/jkef-release.tar.gz"
EXTRACT_DIR="${WORK_ROOT}/release"
rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"

fetch_latest_release_json() {
  local hdr=()
  if [[ -n "$TOKEN" ]]; then
    hdr=(-H "Authorization: token ${TOKEN}" -H "Accept: application/vnd.github+json")
  else
    hdr=(-H "Accept: application/vnd.github+json")
  fi
  curl -fsSL "${hdr[@]}" "${API_BASE}/repos/${REPO}/releases/latest"
}

download_asset() {
  local url="$1"
  local hdr=()
  if [[ -n "$TOKEN" ]]; then
    hdr=(-H "Authorization: token ${TOKEN}" -H "Accept: application/octet-stream")
  else
    hdr=(-H "Accept: application/octet-stream")
  fi
  curl -fsSL -L "${hdr[@]}" "$url" -o "$TAR_PATH"
}

log "Fetching latest release ..."
set +e
REL_JSON="$(fetch_latest_release_json)"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  # likely needs token
  if [[ -z "$TOKEN" ]]; then
    has_tty || die "Release-Abfrage fehlgeschlagen. Kein TTY fuer Token. Setze GH_TOKEN."
    TOKEN="$(prompt_secret_tty "GitHub Token benoetigt. Bitte eingeben und ENTER: ")"
    [[ -n "$TOKEN" ]] || die "Kein Token eingegeben."
    REL_JSON="$(fetch_latest_release_json)"
  else
    die "Release-Abfrage fehlgeschlagen (Token evtl. falsch?)."
  fi
fi

ASSET_URL="$(printf "%s" "$REL_JSON" | select_asset_url)"
[[ -n "$ASSET_URL" ]] || die "Kein Release-Asset (.tar.gz) gefunden."

log "Downloading release asset ..."
set +e
download_asset "$ASSET_URL"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  # try token prompt if not set
  if [[ -z "$TOKEN" ]]; then
    has_tty || die "Download fehlgeschlagen. Kein TTY fuer Token. Setze GH_TOKEN."
    TOKEN="$(prompt_secret_tty "Download braucht Token. Bitte eingeben und ENTER: ")"
    [[ -n "$TOKEN" ]] || die "Kein Token eingegeben."
    download_asset "$ASSET_URL"
  else
    die "Download fehlgeschlagen (Token evtl. falsch?)."
  fi
fi

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

# ensure we run inner installer interactive if possible
if has_tty; then
  bash "${INNER}/install.sh" < /dev/tty
else
  bash "${INNER}/install.sh"
fi

log "Done."
