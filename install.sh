#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"

TARGET_DIR_NAME="jkef-trading-bot"   # so heißt der Ordner im Tar (bei dir so!)
CACHE_DIR_NAME=".cache/jkef"
LOG_FILE_NAME="jkef-install.log"

die(){ echo "FEHLER: $*" >&2; exit 1; }
log(){ echo "• $*"; }

[[ "${EUID}" -eq 0 ]] || die "Bitte via sudo ausführen: curl -fsSL <URL> | sudo bash"

RUN_USER="${SUDO_USER:-}"
[[ -n "$RUN_USER" && "$RUN_USER" != "root" ]] || die "SUDO_USER fehlt/root. Bitte als normaler User mit sudo starten."

HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$RUN_USER}"
[[ -d "$HOME_DIR" ]] || die "Home nicht gefunden: $HOME_DIR"

TARGET_DIR="${HOME_DIR}/${TARGET_DIR_NAME}"
CACHE_DIR="${HOME_DIR}/${CACHE_DIR_NAME}"
LOG_FILE="${HOME_DIR}/${LOG_FILE_NAME}"

need_cmd(){ command -v "$1" >/dev/null 2>&1; }
if ! need_cmd curl || ! need_cmd jq || ! need_cmd tar; then
  log "Installiere Pakete: curl jq tar …"
  apt-get update -y
  apt-get install -y curl jq tar
fi

# Alles in ein einziges Log (und trotzdem am Bildschirm)
exec > >(tee -a "$LOG_FILE") 2>&1

echo "== JKEF Simple Installer =="
echo "User   : $RUN_USER"
echo "Home   : $HOME_DIR"
echo "Target : $TARGET_DIR"
echo "Log    : $LOG_FILE"
echo

# Token via TTY
echo "============================================================"
echo "GitHub Token eingeben (Eingabe bleibt unsichtbar) und ENTER."
echo "============================================================"
read -rs -p "Token: " TOKEN < /dev/tty
echo "" > /dev/tty
TOKEN="$(printf "%s" "$TOKEN" | tr -d '\r\n')"
[[ -n "$TOKEN" ]] || die "Kein Token eingegeben."

# Auth Header token vs Bearer
auth_header=""
code_token="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${TOKEN}" https://api.github.com/user || true)"
if [[ "$code_token" == "200" ]]; then
  auth_header="Authorization: token ${TOKEN}"
else
  code_bearer="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" https://api.github.com/user || true)"
  [[ "$code_bearer" == "200" ]] || die "Token ungültig (/user: token=${code_token}, bearer=${code_bearer})"
  auth_header="Authorization: Bearer ${TOKEN}"
fi

# Latest Release Asset
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
log "Hole latest release…"
release_json="$(curl -fsSL -H "$auth_header" -H "Accept: application/vnd.github+json" "$API")"
asset_name="$(echo "$release_json" | jq -r '.assets[]?.name | select(endswith(".tar.gz"))' | head -n1)"
asset_url="$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .url' | head -n1)"

[[ -n "$asset_name" && -n "$asset_url" && "$asset_url" != "null" ]] || die "Kein .tar.gz Asset im Latest Release gefunden."

log "Asset: $asset_name"

# Download nach ~/.cache/jkef/
sudo -u "$RUN_USER" mkdir -p "$CACHE_DIR"
TAR_PATH="${CACHE_DIR}/${asset_name}"

log "Download -> $TAR_PATH (als $RUN_USER)"
sudo -u "$RUN_USER" bash -lc \
  "curl -fL -H '$auth_header' -H 'Accept: application/octet-stream' '$asset_url' -o '$TAR_PATH'"

# Zielordner ersetzen (deterministisch, KEIN Workdir)
log "Ersetze Zielordner: $TARGET_DIR"
rm -rf "$TARGET_DIR"
sudo -u "$RUN_USER" mkdir -p "$TARGET_DIR"

# Entpacken: Tar enthält bei dir den Ordner jkef-trading-bot/ oben drin.
# Wir entpacken ins HOME und haben danach /home/user/jkef-trading-bot/...
log "Entpacken ins HOME (als $RUN_USER)"
sudo -u "$RUN_USER" bash -lc "cd '$HOME_DIR' && tar -xzf '$TAR_PATH'"

# Prüfen: install.sh muss existieren
INSTALL_SH="${TARGET_DIR}/install.sh"
[[ -f "$INSTALL_SH" ]] || die "install.sh nicht gefunden unter: $INSTALL_SH"

sudo -u "$RUN_USER" chmod +x "$INSTALL_SH" 2>/dev/null || true

log "Starte: $INSTALL_SH (als root)"
cd "$TARGET_DIR"
export INSTALL_USER="$RUN_USER"
export INSTALL_HOME="$HOME_DIR"
bash "./install.sh"

echo
echo "== DONE =="
