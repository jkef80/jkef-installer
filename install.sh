#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# JKEF Bootstrap Installer (Putty-safe + curl|sudo bash safe)
# - Menu via /dev/tty (u/i/e), no arrow keys
# - Detects existing /opt/jkef-trading-bot
# - INSTALL: asks token, wipes target
# - UPDATE: keeps .env + data
# - Downloads latest release asset (.tar.gz) from jkef80/jkef-bot-updates
#   using GitHub API Asset-ID endpoint (reliable binary download)
# - Extracts and runs inner install.sh from the release tarball
# ------------------------------------------------------------

REPO_DEFAULT="jkef80/jkef-bot-updates"
TARGET_DEFAULT="/opt/jkef-trading-bot"
WORK_ROOT_DEFAULT="/tmp/jkef-install"
API_BASE="https://api.github.com"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

need_root() { [[ ${EUID:-0} -eq 0 ]] || die "Bitte mit sudo ausfuehren: sudo bash install.sh"; }

tty_path() { [[ -r /dev/tty && -w /dev/tty ]] && echo "/dev/tty" || echo ""; }

get_run_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then echo "$SUDO_USER"; else echo "${USER:-root}"; fi
}

get_home_dir() {
  local u="$1"
  local h
  h="$(getent passwd "$u" | cut -d: -f6 || true)"
  [[ -n "$h" ]] && echo "$h" || echo "/root"
}

prompt_secret_tty() {
  local prompt="$1"
  local tty; tty="$(tty_path)"
  [[ -n "$tty" ]] || die "Kein TTY fuer Token-Eingabe. Setze GH_TOKEN oder JKEF_GH_TOKEN als Env."
  printf "%s" "$prompt" >"$tty"
  stty -echo <"$tty"
  local val=""
  IFS= read -r val <"$tty" || true
  stty echo <"$tty"
  printf "\n" >"$tty"
  echo "$val"
}

choose_mode_plain() {
  local installed="$1"   # yes/no
  local default="u"
  [[ "$installed" == "no" ]] && default="i"

  local tty; tty="$(tty_path)"
  [[ -n "$tty" ]] || die "Kein TTY verfuegbar. Nutze: sudo bash install.sh --install|--update"

  {
    echo ""
    echo "JKEF Installer (Putty-safe)"
    echo "==========================="
    if [[ "$installed" == "yes" ]]; then
      echo "Erkannt: INSTALLIERT -> Default: UPDATE (behaelt .env + data)"
    else
      echo "Erkannt: NICHT installiert -> Default: INSTALL (Token wird abgefragt)"
    fi
    echo ""
    echo " [u] Update   (behaelt ${TARGET_DEFAULT}/.env und ${TARGET_DEFAULT}/data)"
    echo " [i] Install  (LOESCHT ${TARGET_DEFAULT} inkl. .env + data)"
    echo " [e] Exit"
    echo ""
    printf "Auswahl (u/i/e) [%s]: " "$default"
  } >"$tty"

  local ans=""
  IFS= read -r ans <"$tty" || true
  ans="${ans:-$default}"

  case "$ans" in
    u|U) echo "update" ;;
    i|I) echo "install" ;;
    e|E) echo "exit" ;;
    *)   echo "invalid" ;;
  esac
}

confirm_install_tty() {
  local target="$1"
  local tty; tty="$(tty_path)"
  [[ -n "$tty" ]] || die "Kein TTY fuer Rueckfrage."
  {
    echo ""
    echo "WARNUNG: INSTALL loescht komplett:"
    echo "  $target"
    echo "inkl. .env + data"
    echo ""
    printf "Wirklich fortfahren? Tippe exakt: JA  (sonst Abbruch): "
  } >"$tty"
  local c=""
  IFS= read -r c <"$tty" || true
  [[ "$c" == "JA" ]]
}

# ---- Robust GitHub request: captures HTTP status + body ----
gh_api_get() {
  local url="$1"
  local token="$2"
  local out="$3"
  local hdr=()
  hdr+=(-H "Accept: application/vnd.github+json")
  [[ -n "$token" ]] && hdr+=(-H "Authorization: token ${token}")

  # write body to $out, print HTTP code to stdout
  curl -sS -L "${hdr[@]}" -o "$out" -w "%{http_code}" "$url"
}

body_is_json_object() {
  local file="$1"
  python3 - <<'PY' "$file"
import sys
p=sys.argv[1]
data=open(p,'rb').read().lstrip()
sys.exit(0 if data.startswith(b'{') else 1)
PY
}

select_asset_id_from_release_file() {
  local file="$1"
  python3 - <<'PY' "$file"
import json,sys
p=sys.argv[1]
j=json.load(open(p,'r',encoding='utf-8',errors='replace'))
assets=j.get("assets") or []
# Prefer .tar.gz
for a in assets:
    n=(a.get("name") or "")
    if n.endswith(".tar.gz") and a.get("id"):
        print(a["id"]); sys.exit(0)
# Fallback: any asset id
for a in assets:
    if a.get("id"):
        print(a["id"]); sys.exit(0)
print("")
PY
}

download_asset_by_id() {
  local repo="$1"
  local asset_id="$2"
  local token="$3"
  local out="$4"

  local url="${API_BASE}/repos/${repo}/releases/assets/${asset_id}"
  local hdr=()
  hdr+=(-H "Accept: application/octet-stream")
  [[ -n "$token" ]] && hdr+=(-H "Authorization: token ${token}")

  curl -sS -L "${hdr[@]}" -o "$out" "$url"
}

is_gzip_file() {
  local f="$1"
  python3 - <<'PY' "$f"
import sys
p=sys.argv[1]
with open(p,'rb') as fp:
    b=fp.read(2)
sys.exit(0 if b == b'\x1f\x8b' else 1)
PY
}

# ---------------- MAIN ----------------
need_root

RUN_USER="$(get_run_user)"
HOME_DIR="$(get_home_dir "$RUN_USER")"

REPO="${JKEF_REPO:-$REPO_DEFAULT}"
TARGET="${JKEF_TARGET:-$TARGET_DEFAULT}"
WORK_ROOT="${JKEF_WORK_ROOT:-$WORK_ROOT_DEFAULT}"
CACHE_DIR="${JKEF_CACHE_DIR:-${HOME_DIR}/.cache/jkef}"

mkdir -p "$WORK_ROOT" "$CACHE_DIR"
chown -R "${RUN_USER}:${RUN_USER}" "$CACHE_DIR" >/dev/null 2>&1 || true

INSTALLED="no"
[[ -d "$TARGET" ]] && INSTALLED="yes"

MODE="${JKEF_INSTALL_MODE:-}"
case "${1:-}" in
  --install) MODE="install" ;;
  --update)  MODE="update" ;;
  "" ) : ;;
  * ) die "Unbekannter Parameter: ${1}. Nutze: --install | --update" ;;
esac

if [[ -z "$MODE" ]]; then
  MODE="$(choose_mode_plain "$INSTALLED")"
fi

case "$MODE" in
  install|update) : ;;
  exit) log "Abbruch."; exit 0 ;;
  invalid) die "Ungueltige Eingabe. Bitte u/i/e verwenden." ;;
  *) die "Ungueltiger Mode: $MODE" ;;
esac

log ""
log "== Einstellungen =="
log "Repo   : $REPO"
log "Target : $TARGET"
log "Mode   : $MODE"
log "User   : $RUN_USER"
log "Cache  : $CACHE_DIR"
log ""

TOKEN="${JKEF_GH_TOKEN:-${GH_TOKEN:-}}"

if [[ "$MODE" == "install" ]]; then
  confirm_install_tty "$TARGET" || { log "Abbruch."; exit 0; }
  [[ -n "$TOKEN" ]] || TOKEN="$(prompt_secret_tty "GitHub Token eingeben (unsichtbar) und ENTER: ")"
  [[ -n "$TOKEN" ]] || die "Kein Token eingegeben."
  rm -rf "$TARGET"
fi

REL_FILE="${WORK_ROOT}/latest_release.json"
TAR_PATH="${CACHE_DIR}/jkef-release.tar.gz"
EXTRACT_DIR="${WORK_ROOT}/release"

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

log "Hole latest Release Info ..."
URL="${API_BASE}/repos/${REPO}/releases/latest"
HTTP_CODE="$(gh_api_get "$URL" "$TOKEN" "$REL_FILE" || true)"

if [[ "$HTTP_CODE" != "200" ]]; then
  log ""
  log "GitHub API HTTP Code: $HTTP_CODE"
  log "Antwort (erste 500 Zeichen):"
  head -c 500 "$REL_FILE" 2>/dev/null || true
  log ""
  die "Release-Abfrage fehlgeschlagen. (Token/Rechte/RateLimit/Netzwerk?)"
fi

if ! body_is_json_object "$REL_FILE"; then
  log ""
  log "GitHub API lieferte kein JSON. Antwort (erste 500 Zeichen):"
  head -c 500 "$REL_FILE" 2>/dev/null || true
  log ""
  die "Keine JSON-Antwort von GitHub erhalten (Proxy/Captive-Portal/Netzwerk?)."
fi

ASSET_ID="$(select_asset_id_from_release_file "$REL_FILE")"
[[ -n "$ASSET_ID" ]] || die "Kein Release-Asset gefunden (keine Asset-ID)."

log "Downloade Asset (via GitHub API Asset-ID) ..."
download_asset_by_id "$REPO" "$ASSET_ID" "$TOKEN" "$TAR_PATH" || die "Download fehlgeschlagen (Token/Rechte?)."

if ! is_gzip_file "$TAR_PATH"; then
  log ""
  log "Download ist kein gzip. Erste 300 Zeichen der Datei:"
  head -c 300 "$TAR_PATH" 2>/dev/null || true
  log ""
  die "Asset-Download lieferte keine .tar.gz Datei (Token/Rechte/Asset?)."
fi

log "Entpacke Release ..."
tar -xzf "$TAR_PATH" -C "$EXTRACT_DIR"

INNER="$EXTRACT_DIR"
shopt -s nullglob
entries=("$EXTRACT_DIR"/*)
shopt -u nullglob
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
  INNER="${entries[0]}"
fi

[[ -f "${INNER}/install.sh" ]] || die "Im Release fehlt install.sh (inner installer)."
chmod +x "${INNER}/install.sh" || true

export JKEF_INSTALL_MODE="$MODE"
export JKEF_GH_TOKEN="$TOKEN"
export GH_TOKEN="$TOKEN"
export JKEF_TARGET="$TARGET"

log ""
log "Starte inneren Installer: ${INNER}/install.sh"
log "-------------------------------------------"
bash "${INNER}/install.sh"

log ""
log "Fertig."
