#!/usr/bin/env bash
set -euo pipefail

REPO_DEFAULT="jkef80/jkef-bot-updates"
TARGET_DEFAULT="/opt/jkef-trading-bot"
WORK_ROOT_DEFAULT="/tmp/jkef-install"
API_BASE="https://api.github.com"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

need_root() { [[ ${EUID:-0} -eq 0 ]] || die "Bitte mit sudo ausfuehren: sudo bash install.sh"; }

tty_path() {
  [[ -r /dev/tty && -w /dev/tty ]] && echo "/dev/tty" || echo ""
}

get_run_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then echo "$SUDO_USER"; else echo "${USER:-root}"; fi
}

get_home_dir() {
  local u="$1"
  local h
  h="$(getent passwd "$u" | cut -d: -f6 || true)"
  [[ -n "$h" ]] && echo "$h" || echo "/root"
}

# Reads from /dev/tty and hides input
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

# Putty-safe menu:
# - prints ALL UI to /dev/tty
# - echoes ONLY selection to stdout
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

select_asset_url_from_release_json() {
  python3 - <<'PY'
import json,sys
j=json.load(sys.stdin)
assets=j.get("assets") or []
for a in assets:
    n=(a.get("name") or "")
    u=(a.get("browser_download_url") or "")
    if n.endswith(".tar.gz") and u:
        print(u); sys.exit(0)
for a in assets:
    u=(a.get("browser_download_url") or "")
    if u:
        print(u); sys.exit(0)
print("")
PY
}

fetch_latest_release_json() {
  local repo="$1"
  local token="$2"
  local -a hdr
  hdr=(-H "Accept: application/vnd.github+json")
  [[ -n "$token" ]] && hdr+=(-H "Authorization: token ${token}")
  curl -fsSL "${hdr[@]}" "${API_BASE}/repos/${repo}/releases/latest"
}

download_asset() {
  local url="$1"
  local token="$2"
  local out="$3"
  local -a hdr
  hdr=(-H "Accept: application/octet-stream")
  [[ -n "$token" ]] && hdr+=(-H "Authorization: token ${token}")
  curl -fsSL -L "${hdr[@]}" "$url" -o "$out"
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

TAR_PATH="${CACHE_DIR}/jkef-release.tar.gz"
EXTRACT_DIR="${WORK_ROOT}/release"
rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"

log "Hole latest Release Info ..."
set +e
REL_JSON="$(fetch_latest_release_json "$REPO" "$TOKEN")"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  if [[ -z "$TOKEN" ]]; then
    log "Release-Abfrage ohne Token fehlgeschlagen. Token wird benoetigt."
    TOKEN="$(prompt_secret_tty "GitHub Token eingeben (unsichtbar) und ENTER: ")"
    [[ -n "$TOKEN" ]] || die "Kein Token eingegeben."
    REL_JSON="$(fetch_latest_release_json "$REPO" "$TOKEN")"
  else
    die "Release-Abfrage fehlgeschlagen (Token falsch oder keine Rechte?)."
  fi
fi

ASSET_URL="$(printf "%s" "$REL_JSON" | select_asset_url_from_release_json)"
[[ -n "$ASSET_URL" ]] || die "Kein Release-Asset gefunden (erwartet .tar.gz im Release)."

log "Downloade Asset ..."
set +e
download_asset "$ASSET_URL" "$TOKEN" "$TAR_PATH"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  if [[ -z "$TOKEN" ]]; then
    log "Download ohne Token fehlgeschlagen. Token wird benoetigt."
    TOKEN="$(prompt_secret_tty "GitHub Token eingeben (unsichtbar) und ENTER: ")"
    [[ -n "$TOKEN" ]] || die "Kein Token eingegeben."
    download_asset "$ASSET_URL" "$TOKEN" "$TAR_PATH"
  else
    die "Download fehlgeschlagen (Token falsch oder keine Rechte?)."
  fi
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
