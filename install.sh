#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# JKEF Bootstrap Installer
# - Downloads latest release asset (.tar.gz) from a private repo
# - Downloads + extracts as HOME user into /home/<user>/jkef-installer/...
# - Executes the *install.sh inside the extracted tar* as root
# ============================================================

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"

# Optional: wenn dein Release-Asset immer gleich heißt, trage es ein.
# Dann wird exakt dieses Asset genommen (falls vorhanden).
PREFERRED_ASSET_NAME=""  # z.B. "jkef-bot-updates.tar.gz"

# Debug: set to 1 for verbose bash
DEBUG="${DEBUG:-0}"

if [[ "$DEBUG" == "1" ]]; then
  set -x
fi

die(){ echo "FEHLER: $*" >&2; exit 1; }
log(){ echo "• $*"; }

# Must be run as root (because final install.sh usually installs services, packages, etc.)
[[ "${EUID}" -eq 0 ]] || die "Bitte via sudo ausführen: curl -fsSL <URL> | sudo bash"

RUN_USER="${SUDO_USER:-}"
[[ -n "$RUN_USER" && "$RUN_USER" != "root" ]] || die "SUDO_USER fehlt/root. Bitte als normaler User mit sudo starten."

HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$RUN_USER}"
[[ -d "$HOME_DIR" ]] || die "Home-Verzeichnis nicht gefunden: $HOME_DIR"

STAMP="$(date +%Y%m%d_%H%M%S)"
BASE_DIR="${HOME_DIR}/jkef-installer"
WORK_DIR="${BASE_DIR}/work/${STAMP}"
EXTRACT_DIR="${WORK_DIR}/extract"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/install_${STAMP}.log"

# Ensure deps
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
if ! need_cmd curl || ! need_cmd jq || ! need_cmd tar; then
  log "Installiere Pakete: curl jq tar …"
  apt-get update -y
  apt-get install -y curl jq tar
fi

# Prepare folders (as RUN_USER)
sudo -u "$RUN_USER" mkdir -p "$EXTRACT_DIR" "$LOG_DIR"
sudo -u "$RUN_USER" chmod 700 "$BASE_DIR" "$WORK_DIR" 2>/dev/null || true

# Capture stdout/stderr to logfile (also show on console)
exec > >(tee -a "$LOG_FILE") 2>&1

echo "== JKEF Installer =="
echo "Repo      : ${REPO_OWNER}/${REPO_NAME}"
echo "User      : ${RUN_USER}"
echo "Home      : ${HOME_DIR}"
echo "Work dir  : ${WORK_DIR}"
echo "Log file  : ${LOG_FILE}"
echo

# Read token from TTY (not from pipe)
echo "============================================================"
echo "GitHub Token eingeben (Eingabe bleibt unsichtbar) und ENTER."
echo "============================================================"
read -rs -p "Token: " TOKEN < /dev/tty
echo "" > /dev/tty

# trim
TOKEN="$(printf "%s" "$TOKEN" | tr -d '\r\n')"
TOKEN="${TOKEN#"${TOKEN%%[![:space:]]*}"}"
TOKEN="${TOKEN%"${TOKEN##*[![:space:]]}"}"
[[ -n "$TOKEN" ]] || die "Kein Token eingegeben."

# Determine auth header (token vs Bearer)
auth_header=""
code_token="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${TOKEN}" https://api.github.com/user || true)"
if [[ "$code_token" == "200" ]]; then
  auth_header="Authorization: token ${TOKEN}"
else
  code_bearer="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" https://api.github.com/user || true)"
  if [[ "$code_bearer" == "200" ]]; then
    auth_header="Authorization: Bearer ${TOKEN}"
  else
    die "Token ungültig (/user: token=${code_token}, bearer=${code_bearer})"
  fi
fi

# Get latest release JSON
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
log "Hole latest release…"
release_json="$(curl -fsSL -H "$auth_header" -H "Accept: application/vnd.github+json" "$API" 2>/dev/null || true)"
[[ -n "$release_json" ]] || die "Kein Zugriff auf Release (API leer). Prüfe Token/Repo."

tag="$(echo "$release_json" | jq -r '.tag_name // empty')"
log "Release tag: ${tag:-<ohne-tag>}"

# Choose asset
asset_name=""
asset_url=""

if [[ -n "$PREFERRED_ASSET_NAME" ]]; then
  asset_name="$PREFERRED_ASSET_NAME"
  asset_url="$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .url'_
