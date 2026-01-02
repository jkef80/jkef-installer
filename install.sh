#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"

# Muss via: curl ... | sudo bash
if [[ "${EUID}" -ne 0 ]]; then
  echo "FEHLER: Bitte so starten: curl -fsSL <URL> | sudo bash"
  exit 1
fi

# Ziel-User bestimmen (Home-User!)
RUN_USER="${SUDO_USER:-}"
if [[ -z "$RUN_USER" || "$RUN_USER" == "root" ]]; then
  echo "FEHLER: Konnte keinen normalen Benutzer bestimmen (SUDO_USER fehlt)."
  echo "Starte so: sudo -u <user> -i bash -c 'curl -fsSL <URL> | sudo bash'"
  exit 1
fi

HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$RUN_USER}"

echo "== JKEF Bootstrap Installer (Download+Extract im HOME, Install als root) =="
echo "Repo : ${REPO_OWNER}/${REPO_NAME}"
echo "User : ${RUN_USER}"
echo "Home : ${HOME_DIR}"
echo

need_cmd(){ command -v "$1" >/dev/null 2>&1; }
if ! need_cmd curl || ! need_cmd jq || ! need_cmd tar; then
  echo "Installiere Pakete: curl jq tar …"
  apt-get update -y
  apt-get install -y curl jq tar
fi

echo "============================================================"
echo "Gib jetzt deinen GitHub Token ein (Eingabe bleibt unsichtbar)."
echo "============================================================"
read -rs -p "Token: " TOKEN < /dev/tty
echo "" > /dev/tty

# trim CR/LF/spaces
TOKEN="$(printf "%s" "$TOKEN" | tr -d '\r\n')"
TOKEN="${TOKEN#"${TOKEN%%[![:space:]]*}"}"
TOKEN="${TOKEN%"${TOKEN##*[![:space:]]}"}"
[[ -n "$TOKEN" ]] || { echo "FEHLER: Kein Token eingegeben."; exit 1; }

# Auth Header automatisch testen: token vs Bearer
auth_header=""
code_token="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${TOKEN}" https://api.github.com/user || true)"
if [[ "$code_token" == "200" ]]; then
  auth_header="Authorization: token ${TOKEN}"
else
  code_bearer="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" https://api.github.com/user || true)"
  if [[ "$code_bearer" == "200" ]]; then
    auth_header="Authorization: Bearer ${TOKEN}"
  else
    echo "FEHLER: Token ungültig (/user: token=${code_token}, bearer=${code_bearer})."
    exit 1
  fi
fi

# Latest release holen
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
release_json="$(curl -fsSL -H "$auth_header" -H "Accept: application/vnd.github+json" "$API" 2>/dev/null || true)"
[[ -n "$release_json" ]] || {
  echo "FEHLER: GitHub API nicht erreichbar oder kein Repo-Zugriff (401/403/404)."
  exit 1
}

tag="$(echo "$release_json" | jq -r '.tag_name // empty')"
asset_name="$(echo "$release_json" | jq -r '.assets[]?.name | select(endswith(".tar.gz"))' | head -n1)"
asset_url="$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .url')"

[[ -n "$asset_name" && -n "$asset_url" && "$asset_url" != "null" ]] || {
  echo "FEHLER: Kein .tar.gz Asset im Latest Release gefunden."
  exit 1
}

echo "Release: ${tag:-<ohne-tag>}"
echo "Asset  : ${asset_name}"
echo

# >>> WICHTIG: Alles nach /home/<user> und als RUN_USER <<<
stamp="$(date +%Y%m%d_%H%M%S)"
base="${HOME_DIR}/jkef_updates/${stamp}"
tar_path="${base}/${asset_name}"
extract_dir="${base}/extract"

echo "Arbeitsordner: $base"
sudo -u "$RUN_USER" mkdir -p "$extract_dir"
sudo -u "$RUN_USER" chmod 700 "$base" || true

echo "Download als ${RUN_USER} nach: $tar_path"
sudo -u "$RUN_USER" bash -lc \
  "curl -fL \
    -H '$auth_header' \
    -H 'Accept: application/octet-stream' \
    '$asset_url' \
    -o '$tar_path'"

echo "Entpacken als ${RUN_USER} nach: $extract_dir"
sudo -u "$RUN_USER" tar -xzf "$tar_path" -C "$extract_dir"

# >>> install.sh robust im entpackten Paket finden (tiefer als 2!) <<<
# Priorität: kürzester Pfad (meist die "richtige" install.sh im Root des Projekts)
echo "Suche install.sh im entpackten Paket …"
mapfile -t installs < <(sudo -u "$RUN_USER" find "$extract_dir" -type f -name "install.sh" -print 2>/dev/null || true)

if [[ "${#installs[@]}" -eq 0 ]]; then
  echo "FEHLER: Keine install.sh im entpackten Paket gefunden."
  echo "Debug: oberste Ebene:"
  sudo -u "$RUN_USER" find "$extract_dir" -maxdepth 3 -mindepth 1 -print | head -n 200 || true
  exit 1
fi

# kürzesten Pfad wählen
best="${installs[0]}"
best_len=${#best}
for f in "${installs[@]}"; do
  if (( ${#f} < best_len )); then
    best="$f"
    best_len=${#f}
  fi
done

proj_dir="$(dirname "$best")"

echo "Gefunden: $best"
sudo -u "$RUN_USER" chmod +x "$best" || true

# >>> Und JETZT: die install.sh aus dem Paket als ROOT starten <<<
echo "Starte install.sh als root aus: $proj_dir"
cd "$proj_dir"

# ENV mitgeben (falls deine install.sh das braucht)
INSTALL_USER="$RUN_USER" INSTALL_HOME="$HOME_DIR" bash "./install.sh"

echo
echo "== DONE =="
echo "Paket liegt unter: $base"
