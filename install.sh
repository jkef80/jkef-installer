#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"

CONFIG_DIR="/etc/jkef-trading-bot"
GITHUB_ENV="${CONFIG_DIR}/github.env"

ADMIN_USER="${SUDO_USER:-${USER}}"
HOME_DIR="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

install_pkgs_if_missing() {
  local pkgs=()
  need_cmd curl || pkgs+=(curl)
  need_cmd jq   || pkgs+=(jq)
  need_cmd tar  || pkgs+=(tar)
  if ((${#pkgs[@]})); then
    echo "Installiere Pakete: ${pkgs[*]} …"
    sudo apt-get update -y
    sudo apt-get install -y "${pkgs[@]}"
  fi
}

echo "== JKEF Bootstrap Installer (HOME-Extract Mode) =="
echo "Repo : ${REPO_OWNER}/${REPO_NAME}"
echo "User : ${ADMIN_USER}"
echo "Home : ${HOME_DIR}"
echo

install_pkgs_if_missing

# --- Token laden oder abfragen ---
TOKEN=""
if [[ -f "$GITHUB_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$GITHUB_ENV" || true
  TOKEN="${GITHUB_TOKEN:-}"
fi

if [[ -z "${TOKEN}" ]]; then
  echo "============================================================"
  echo "Gib jetzt deinen GitHub Token ein (Eingabe bleibt unsichtbar)."
  echo "WICHTIG: Danach ENTER drücken."
  echo "============================================================"
  read -r -s TOKEN
  echo
  sudo mkdir -p "$CONFIG_DIR"
  sudo bash -c "umask 077; cat > '$GITHUB_ENV' <<EOF
GITHUB_TOKEN=$TOKEN
EOF"
  echo "GitHub-Zugang gespeichert: $GITHUB_ENV (600)"
fi

AUTH_HEADER=("Authorization: token ${TOKEN}")

# --- Latest Release holen ---
echo
echo "Hole Latest Release von GitHub …"
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

set +e
release_json="$(curl -fsSL -H "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github+json" "$API" 2>/dev/null)"
rc=$?
set -e
if [[ $rc -ne 0 || -z "$release_json" ]]; then
  echo "FEHLER: GitHub API nicht erreichbar oder Token ungültig (401/403)."
  echo "Token reset:"
  echo "  sudo rm -f $GITHUB_ENV"
  exit 1
fi

tag="$(echo "$release_json" | jq -r '.tag_name // empty')"
echo "Gefundenes Release: ${tag:-<ohne-tag>}"

asset_name="$(echo "$release_json" | jq -r '.assets[]?.name | select(endswith(".tar.gz"))' | head -n1)"
asset_url="$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .url')"

if [[ -z "${asset_name}" || -z "${asset_url}" || "${asset_url}" == "null" ]]; then
  echo "FEHLER: Kein .tar.gz Asset im Latest Release gefunden."
  exit 1
fi

echo "Asset: $asset_name"

# --- Download nach HOME ---
sudo -u "$ADMIN_USER" mkdir -p "$HOME_DIR"
dest_tar="${HOME_DIR}/${asset_name}"

echo "Download nach: $dest_tar"
curl -fL \
  -H "${AUTH_HEADER[@]}" \
  -H "Accept: application/octet-stream" \
  "$asset_url" \
  -o "$dest_tar"

echo "OK: Download fertig."

# --- Entpacken im HOME in einen frischen Ordner ---
stamp="$(date +%Y%m%d_%H%M%S)"
extract_dir="${HOME_DIR}/jkef-release_${stamp}"

echo "Entpacke nach: $extract_dir"
sudo -u "$ADMIN_USER" mkdir -p "$extract_dir"
sudo -u "$ADMIN_USER" tar -xzf "$dest_tar" -C "$extract_dir"

# --- Projekt-Root finden (wo install.sh liegt) ---
cand="$(find "$extract_dir" -maxdepth 4 -type f -name install.sh -print -quit || true)"
if [[ -z "$cand" ]]; then
  echo "FEHLER: Im entpackten Paket keine install.sh gefunden."
  echo "Inhalt (Top-Level):"
  ls -la "$extract_dir" || true
  exit 1
fi

proj="$(dirname "$cand")"
echo "Projektverzeichnis: $proj"

# --- install.sh im HOME starten (die kopiert dann selbst nach /opt/...) ---
echo
echo "Starte Bot-Installer aus HOME (macht Copy nach /opt selbst):"
echo "  $cand"
echo

# sicherstellen, dass install.sh ausführbar ist
sudo -u "$ADMIN_USER" chmod +x "$cand" || true

# WICHTIG: als sudo starten, weil install.sh nach /opt und systemd schreibt
cd "$proj"
sudo bash ./install.sh

echo
echo "== DONE =="
echo "Tar:     $dest_tar"
echo "Extract: $extract_dir"
