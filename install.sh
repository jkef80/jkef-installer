#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"

# Muss via: curl ... | sudo bash
if [[ "${EUID}" -ne 0 ]]; then
  echo "FEHLER: Bitte so starten: curl -fsSL ... | sudo bash"
  exit 1
fi

# User bestimmen, dessen Home wir nutzen
RUN_USER="${SUDO_USER:-admin}"
HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$RUN_USER}"

echo "== JKEF Bootstrap Installer (HOME-USER Download+Extract Mode) =="
echo "Repo : ${REPO_OWNER}/${REPO_NAME}"
echo "User : ${RUN_USER}"
echo "Home : ${HOME_DIR}"
echo

# deps
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
if ! need_cmd curl || ! need_cmd jq || ! need_cmd tar; then
  echo "Installiere Pakete: curl jq tar …"
  apt-get update -y
  apt-get install -y curl jq tar
fi

# Token abfragen (immer!)
echo "============================================================"
echo "Gib jetzt deinen GitHub Token ein (Eingabe bleibt unsichtbar)."
echo "WICHTIG: Danach ENTER drücken."
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
if [[ -z "${release_json}" ]]; then
  echo "FEHLER: GitHub API nicht erreichbar oder kein Repo-Zugriff (401/403/404)."
  exit 1
fi

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

# Arbeitsordner im HOME des RUN_USER (alles als RUN_USER!)
stamp="$(date +%Y%m%d_%H%M%S)"
base="${HOME_DIR}/jkef-release_${stamp}"
tar_path="${base}/${asset_name}"
extract_dir="${base}/extract"

# als RUN_USER anlegen, damit garantiert Home-Rechte passen
sudo -u "$RUN_USER" mkdir -p "$extract_dir"
sudo -u "$RUN_USER" chmod 700 "$base"

echo "Download nach: $tar_path (als ${RUN_USER})"
# Download als RUN_USER (nicht als root)
sudo -u "$RUN_USER" bash -lc \
  "curl -fL \
    -H '$auth_header' \
    -H 'Accept: application/octet-stream' \
    '$asset_url' \
    -o '$tar_path'"

echo "Entpacke nach: $extract_dir (als ${RUN_USER})"
sudo -u "$RUN_USER" tar -xzf "$tar_path" -C "$extract_dir"

# install.sh finden (root oder 1 Ebene tiefer)
proj=""
if sudo -u "$RUN_USER" test -f "$extract_dir/install.sh"; then
  proj="$extract_dir"
else
  cand="$(sudo -u "$RUN_USER" find "$extract_dir" -maxdepth 2 -type f -name install.sh -print -quit || true)"
  [[ -n "$cand" ]] && proj="$(dirname "$cand")"
fi

[[ -n "$proj" ]] || {
  echo "FEHLER: Im entpackten Paket wurde keine install.sh gefunden."
  echo "Inhalt:"
  sudo -u "$RUN_USER" ls -la "$extract_dir" || true
  exit 1
}

echo
echo "Starte Bot-Installer aus: $proj/install.sh"
sudo -u "$RUN_USER" chmod +x "$proj/install.sh" || true

# Wichtig: von dort starten – der Rest ist Aufgabe des Bot-install.sh
cd "$proj"
bash ./install.sh

echo
echo "== DONE =="
echo "Release liegt unter: $base"
