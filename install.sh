#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"
TARGET_DIR="/opt/jkef-trading-bot"
ADMIN_USER="${SUDO_USER:-admin}"

echo "== JKEF Bootstrap Installer (SIMPLE MODE) =="

# --- deps ---
need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }
install_pkg() { sudo apt-get update -y && sudo apt-get install -y "$@"; }

pkgs=()
need_cmd curl || pkgs+=(curl)
need_cmd jq   || pkgs+=(jq)
need_cmd tar  || pkgs+=(tar)
if ((${#pkgs[@]})); then
  echo "Installiere Pakete: ${pkgs[*]} …"
  install_pkg "${pkgs[@]}"
fi

echo
echo "GitHub Updates-Repo [${REPO_OWNER}/${REPO_NAME}]"
echo

# --- token (optional but recommended for private repos / rate limits) ---
GITHUB_ENV="/etc/jkef-trading-bot/github.env"
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
  sudo mkdir -p /etc/jkef-trading-bot
  sudo bash -c "umask 077; cat > '$GITHUB_ENV' <<EOF
GITHUB_TOKEN=$TOKEN
EOF"
  echo "GitHub-Zugang gespeichert: $GITHUB_ENV (600)"
fi

AUTH_HEADER=("Authorization: token ${TOKEN}")

# --- fetch latest release ---
echo "Hole Latest Release von GitHub …"
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
release_json="$(curl -fsSL -H "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github+json" "$API")"

tag="$(echo "$release_json" | jq -r '.tag_name // empty')"
echo "Gefundenes Release: ${tag:-<ohne-tag>}"

asset_name="$(echo "$release_json" | jq -r '.assets[]?.name | select(endswith(".tar.gz"))' | head -n1)"
asset_url="$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .url' )"

if [[ -z "${asset_name}" || -z "${asset_url}" || "${asset_url}" == "null" ]]; then
  echo "FEHLER: Kein .tar.gz Asset im Latest Release gefunden."
  exit 1
fi

echo "Gefundenes Asset:   $asset_name"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "Download (via Asset API) …"
curl -fL \
  -H "${AUTH_HEADER[@]}" \
  -H "Accept: application/octet-stream" \
  "$asset_url" \
  -o "$tmp/release.tar.gz"

# --- extract ---
echo "Entpacke in Staging …"
mkdir -p "$tmp/extract"
tar -xzf "$tmp/release.tar.gz" -C "$tmp/extract"

# --- find project root: either extract/*/install.sh OR extract/install.sh ---
proj=""
if [[ -f "$tmp/extract/install.sh" ]]; then
  proj="$tmp/extract"
else
  # one level deep
  cand="$(find "$tmp/extract" -maxdepth 2 -type f -name install.sh -print -quit || true)"
  if [[ -n "$cand" ]]; then
    proj="$(dirname "$cand")"
  fi
fi

if [[ -z "$proj" ]]; then
  echo "FEHLER: Im Paket wurde keine install.sh gefunden."
  echo "Top-Level Inhalt:"
  ls -la "$tmp/extract" || true
  exit 1
fi

# --- sanity check: app/main.py must exist (classic layout) ---
if [[ ! -f "$proj/app/main.py" ]]; then
  echo "FEHLER: Source tree unvollständig (app/main.py fehlt)."
  echo "Gefundenes Projektverzeichnis: $proj"
  echo "Inhalt (Top-Level):"
  ls -la "$proj" || true
  exit 1
fi

# --- deploy: delete & replace (as requested) ---
echo "Deploy nach $TARGET_DIR (ALLES ALT WIRD GELÖSCHT) …"
sudo systemctl stop jkef-trading-bot >/dev/null 2>&1 || true

sudo rm -rf "$TARGET_DIR"
sudo mkdir -p "$TARGET_DIR"

# copy
sudo cp -a "$proj/." "$TARGET_DIR/"

# ownership so web/local operations work
sudo chown -R "${ADMIN_USER}:${ADMIN_USER}" "$TARGET_DIR"
sudo find "$TARGET_DIR" -type d -exec chmod 755 {} \;
sudo find "$TARGET_DIR" -type f -exec chmod 644 {} \;
sudo chmod +x "$TARGET_DIR/install.sh" || true

echo "Starte Bot-Installer aus $TARGET_DIR/install.sh …"
cd "$TARGET_DIR"
sudo bash ./install.sh

echo
echo "== DONE (Bootstrap Simple) =="
