#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# JKEF Installer (Bootstrap)
#
# Zweck:
# - Latest Release (.tar.gz) aus privatem Repo jkef80/jkef-bot-updates laden
# - nach /home/<user>/jkef-trading-bot entpacken (als User)
# - /home/<user>/jkef-trading-bot/install.sh starten (als root)
#
# Design-Ziele:
# - keine verwirrenden Zeitstempel-Workdirs
# - fester Zielpfad, immer gleich
# - funktioniert auch bei: curl ... | sudo bash
# ============================================================

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"

# Erwarteter Top-Level Ordner im Tarball:
# (Bei dir: jkef-trading-bot/)
TARGET_DIR_NAME="jkef-trading-bot"

# Optional: Wenn du ein bestimmtes Asset erzwingen willst, hier setzen.
# Sonst nimmt er das erste .tar.gz im latest release.
PREFERRED_ASSET_NAME=""

CACHE_DIR_REL=".cache/jkef"
LOG_FILE_NAME="jkef-install.log"

die(){ echo "FEHLER: $*" >&2; exit 1; }
log(){ echo "• $*"; }

# --- Preconditions ---
[[ "${EUID}" -eq 0 ]] || die "Bitte via sudo ausführen: curl -fsSL <URL> | sudo bash"

RUN_USER="${SUDO_USER:-}"
[[ -n "$RUN_USER" && "$RUN_USER" != "root" ]] || die "SUDO_USER fehlt/root. Bitte als normaler User mit sudo starten."

HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$RUN_USER}"
[[ -d "$HOME_DIR" ]] || die "Home nicht gefunden: $HOME_DIR"

TARGET_DIR="${HOME_DIR}/${TARGET_DIR_NAME}"
CACHE_DIR="${HOME_DIR}/${CACHE_DIR_REL}"
LOG_FILE="${HOME_DIR}/${LOG_FILE_NAME}"

# --- Dependencies ---
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
if ! need_cmd curl || ! need_cmd jq || ! need_cmd tar; then
  log "Installiere Pakete: curl jq tar …"
  apt-get update -y
  apt-get install -y curl jq tar
fi

# --- Logging: file + console ---
exec > >(tee -a "$LOG_FILE") 2>&1

echo "== JKEF Installer (Bootstrap) =="
echo "Repo   : ${REPO_OWNER}/${REPO_NAME}"
echo "User   : ${RUN_USER}"
echo "Home   : ${HOME_DIR}"
echo "Target : ${TARGET_DIR}"
echo "Cache  : ${CACHE_DIR}"
echo "Log    : ${LOG_FILE}"
echo

# --- Token read from TTY (not from pipe) ---
echo "============================================================"
echo "GitHub Token eingeben (Eingabe bleibt unsichtbar) und ENTER."
echo "============================================================"
read -rs -p "Token: " TOKEN < /dev/tty
echo "" > /dev/tty
TOKEN="$(printf "%s" "$TOKEN" | tr -d '\r\n')"
[[ -n "$TOKEN" ]] || die "Kein Token eingegeben."

# --- Auth header: token vs Bearer ---
auth_header=""
code_token="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${TOKEN}" https://api.github.com/user || true)"
if [[ "$code_token" == "200" ]]; then
  auth_header="Authorization: token ${TOKEN}"
else
  code_bearer="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" https://api.github.com/user || true)"
  [[ "$code_bearer" == "200" ]] || die "Token ungültig (/user: token=${code_token}, bearer=${code_bearer})"
  auth_header="Authorization: Bearer ${TOKEN}"
fi

# --- Get latest release ---
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
log "Hole latest release…"
release_json="$(curl -fsSL -H "$auth_header" -H "Accept: application/vnd.github+json" "$API")"

tag="$(echo "$release_json" | jq -r '.tag_name // empty')"
log "Release tag: ${tag:-<ohne-tag>}"

# --- Choose asset (.tar.gz) ---
asset_name=""
asset_url=""

if [[ -n "$PREFERRED_ASSET_NAME" ]]; then
  asset_name="$PREFERRED_ASSET_NAME"
  asset_url="$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .url' | head -n1)"
fi

if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
  asset_name="$(echo "$release_json" | jq -r '.assets[]?.name | select(endswith(".tar.gz"))' | head -n1)"
  asset_url="$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .url' | head -n1)"
fi

[[ -n "$asset_name" && -n "$asset_url" && "$asset_url" != "null" ]] || die "Kein .tar.gz Asset im Latest Release gefunden."
log "Asset: $asset_name"

# --- Ensure cache dir (as RUN_USER) ---
sudo -u "$RUN_USER" mkdir -p "$CACHE_DIR"
TAR_PATH="${CACHE_DIR}/${asset_name}"

# --- Download as RUN_USER into /home/<user> ---
log "Download -> $TAR_PATH (als $RUN_USER)"
sudo -u "$RUN_USER" bash -lc \
  "curl -fL -H '$auth_header' -H 'Accept: application/octet-stream' '$asset_url' -o '$TAR_PATH'"

# --- Replace target folder deterministically ---
log "Ersetze Zielordner: $TARGET_DIR"
rm -rf "$TARGET_DIR"

# Entpacken als RUN_USER direkt ins HOME
# Hinweis: Tar enthält bei dir den Top-Ordner jkef-trading-bot/
log "Entpacken ins HOME (als $RUN_USER)"
sudo -u "$RUN_USER" bash -lc "cd '$HOME_DIR' && tar -xzf '$TAR_PATH'"

# --- Validate expected structure ---
INSTALL_SH="${TARGET_DIR}/install.sh"
[[ -f "$INSTALL_SH" ]] || {
  log "Debug: Inhalt von $HOME_DIR (jkef*)"
  sudo -u "$RUN_USER" bash -lc "ls -la '$HOME_DIR' | sed -n '1,200p'" || true
  die "install.sh nicht gefunden unter: $INSTALL_SH (Tar-Struktur passt nicht zu TARGET_DIR_NAME='${TARGET_DIR_NAME}')"
}

sudo -u "$RUN_USER" chmod +x "$INSTALL_SH" 2>/dev/null || true

# --- Run the tar's install.sh as root, but with TTY input ---
# WICHTIG: Bei 'curl | sudo bash' ist STDIN ein Pipe -> read() in install.sh bekommt EOF.
# Mit < /dev/tty ist install.sh wieder interaktiv.
log "Starte: $INSTALL_SH (als root, interaktiv via /dev/tty)"
cd "$TARGET_DIR"

export INSTALL_USER="$RUN_USER"
export INSTALL_HOME="$HOME_DIR"
export JKEF_RELEASE_TAG="${tag:-}"
export JKEF_TAR_PATH="$TAR_PATH"

bash "./install.sh" < /dev/tty

echo
echo "== DONE =="
echo "Target: $TARGET_DIR"
echo "Log   : $LOG_FILE"
