#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"
TARGET_DIR="/opt/jkef-trading-bot"
CONFIG_DIR="/etc/jkef-trading-bot"
GITHUB_ENV="${CONFIG_DIR}/github.env"

# Wer startet den Installer?
ADMIN_USER="${SUDO_USER:-${USER}}"
HOME_DIR="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
DOWNLOAD_DIR="${HOME_DIR}"

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

echo "== JKEF Bootstrap Installer (Minimal) =="
echo "Repo: ${REPO_OWNER}/${REPO_NAME}"
echo "User: ${ADMIN_USER}"
echo "Home: ${HOME_DIR}"
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
  echo "Tipp: Token prüfen oder Datei löschen zum Neuabfragen:"
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
mkdir -p "$DOWNLOAD_DIR"
dest_tar="${DOWNLOAD_DIR}/${asset_name}"

echo "Download nach: $dest_tar"
curl -fL \
  -H "${AUTH_HEADER[@]}" \
  -H "Accept: application/octet-stream" \
  "$asset_url" \
  -o "$dest_tar"

echo "OK: Download fertig."

# --- Entpacken in temp ---
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "Entpacke nach Staging: $tmp/extract"
mkdir -p "$tmp/extract"
tar -xzf "$dest_tar" -C "$tmp/extract"

# --- Projekt-Root finden: irgendwo install.sh im entpackten Baum ---
proj=""
cand="$(find "$tmp/extract" -maxdepth 4 -type f -name install.sh -print -quit || true)"
if [[ -n "$cand" ]]; then
  proj="$(dirname "$cand")"
fi

if [[ -z "$proj" ]]; then
  echo "FEHLER: Im Paket keine install.sh gefunden."
  echo "Top-Level Inhalt:"
  ls -la "$tmp/extract" || true
  exit 1
fi

echo "Projektverzeichnis erkannt: $proj"

# --- Deploy nach /opt (ersetzen) ---
echo "Deploy nach $TARGET_DIR (ersetze vorhandene Installation) …"
sudo systemctl stop jkef-trading-bot >/dev/null 2>&1 || true

sudo rm -rf "$TARGET_DIR"
sudo mkdir -p "$TARGET_DIR"
sudo cp -a "$proj/." "$TARGET_DIR/"

# Eigentümer auf ADMIN_USER, damit UI/Updates später nicht an Rechten sterben
sudo chown -R "${ADMIN_USER}:${ADMIN_USER}" "$TARGET_DIR"
sudo find "$TARGET_DIR" -type d -exec chmod 755 {} \;
sudo find "$TARGET_DIR" -type f -exec chmod 644 {} \;
sudo chmod +x "$TARGET_DIR/install.sh" || true

# --- Bot-Installer starten ---
if [[ ! -f "$TARGET_DIR/install.sh" ]]; then
  echo "FEHLER: Nach Deploy fehlt $TARGET_DIR/install.sh"
  ls -la "$TARGET_DIR" || true
  exit 1
fi

echo
echo "Starte Bot-Installer: $TARGET_DIR/install.sh"
cd "$TARGET_DIR"
sudo bash ./install.sh

echo
echo "== DONE =="
echo "Tar liegt unter: $dest_tar"
echo "Installationspfad: $TARGET_DIR"
