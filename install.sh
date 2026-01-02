#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"

die(){ echo "FEHLER: $*" >&2; exit 1; }
log(){ echo "• $*"; }

[[ "${EUID}" -eq 0 ]] || die "Bitte via sudo ausführen: curl -fsSL <URL> | sudo bash"

RUN_USER="${SUDO_USER:-}"
[[ -n "$RUN_USER" && "$RUN_USER" != "root" ]] || die "SUDO_USER fehlt/root. Bitte als normaler User mit sudo starten."

HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$RUN_USER}"
[[ -d "$HOME_DIR" ]] || die "Home-Verzeichnis nicht gefunden: $HOME_DIR"

need_cmd(){ command -v "$1" >/dev/null 2>&1; }
if ! need_cmd curl || ! need_cmd jq || ! need_cmd tar; then
  log "Installiere Pakete: curl jq tar …"
  apt-get update -y
  apt-get install -y curl jq tar
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BASE_DIR="${HOME_DIR}/jkef-installer"
WORK_DIR="${BASE_DIR}/work/${STAMP}"
EXTRACT_DIR="${WORK_DIR}/extract"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/install_${STAMP}.log"

sudo -u "$RUN_USER" mkdir -p "$EXTRACT_DIR" "$LOG_DIR"
sudo -u "$RUN_USER" chmod 700 "$BASE_DIR" "$WORK_DIR" 2>/dev/null || true

exec > >(tee -a "$LOG_FILE") 2>&1

echo "== JKEF Installer =="
echo "Repo      : ${REPO_OWNER}/${REPO_NAME}"
echo "User      : ${RUN_USER}"
echo "Home      : ${HOME_DIR}"
echo "Work dir  : ${WORK_DIR}"
echo "Log file  : ${LOG_FILE}"
echo

echo "============================================================"
echo "GitHub Token eingeben (Eingabe bleibt unsichtbar) und ENTER."
echo "============================================================"
read -rs -p "Token: " TOKEN < /dev/tty
echo "" > /dev/tty

TOKEN="$(printf "%s" "$TOKEN" | tr -d '\r\n')"
[[ -n "$TOKEN" ]] || die "Kein Token eingegeben."

# Auth Header (token vs Bearer)
auth_header=""
code_token="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${TOKEN}" https://api.github.com/user || true)"
if [[ "$code_token" == "200" ]]; then
  auth_header="Authorization: token ${TOKEN}"
else
  code_bearer="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" https://api.github.com/user || true)"
  [[ "$code_bearer" == "200" ]] || die "Token ungültig (/user: token=${code_token}, bearer=${code_bearer})"
  auth_header="Authorization: Bearer ${TOKEN}"
fi

# Latest Release
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
log "Hole latest release…"
release_json="$(curl -fsSL -H "$auth_header" -H "Accept: application/vnd.github+json" "$API")"

tag="$(echo "$release_json" | jq -r '.tag_name // empty')"
asset_name="$(echo "$release_json" | jq -r '.assets[]?.name | select(endswith(".tar.gz"))' | head -n1)"
asset_url="$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .url' | head -n1)"

[[ -n "$asset_name" && -n "$asset_url" && "$asset_url" != "null" ]] || die "Kein .tar.gz Asset im Latest Release gefunden."

log "Release tag: ${tag:-<ohne-tag>}"
log "Asset      : $asset_name"

TAR_PATH="${WORK_DIR}/${asset_name}"

# Download als USER nach /home/<user>/...
log "Download (als ${RUN_USER}) nach: ${TAR_PATH}"
sudo -u "$RUN_USER" bash -lc \
  "curl -fL -H '$auth_header' -H 'Accept: application/octet-stream' '$asset_url' -o '$TAR_PATH'"

# Extract als USER nach /home/<user>/...
log "Entpacken (als ${RUN_USER}) nach: ${EXTRACT_DIR}"
sudo -u "$RUN_USER" tar -xzf "$TAR_PATH" -C "$EXTRACT_DIR"

# --- SUPER EINFACH: Top-Level Ordner nehmen, dann install.sh ---
top_dir="$(sudo -u "$RUN_USER" find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d -print | head -n 1 || true)"

install_path=""
if [[ -n "$top_dir" && -f "$top_dir/install.sh" ]]; then
  install_path="$top_dir/install.sh"
else
  # Fallback: falls tar anders ist, maxdepth 2 reicht in deinem Layout vollkommen
  install_path="$(sudo -u "$RUN_USER" find "$EXTRACT_DIR" -maxdepth 2 -type f -name 'install.sh' -print -quit || true)"
fi

[[ -n "$install_path" ]] || die "install.sh nicht gefunden im entpackten Paket."

log "Gefunden install.sh: $install_path"
sudo -u "$RUN_USER" chmod +x "$install_path" 2>/dev/null || true

# install.sh aus dem TAR als root starten
proj_dir="$(dirname "$install_path")"
log "Starte TAR-install.sh als root aus: $proj_dir"
cd "$proj_dir"

export INSTALL_USER="$RUN_USER"
export INSTALL_HOME="$HOME_DIR"
export JKEF_RELEASE_TAG="${tag:-}"

bash "./install.sh"

echo
echo "== DONE =="
echo "Work: ${WORK_DIR}"
echo "Log : ${LOG_FILE}"
