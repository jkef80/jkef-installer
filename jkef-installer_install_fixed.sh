#!/usr/bin/env bash
set -euo pipefail

# == JKEF Bootstrap Installer ==
# Lädt das Latest Release-Asset aus jkef-bot-updates und startet anschließend den Bot-Installer.
# Robust gegen unterschiedliche TAR-Strukturen (mit/ohne Top-Level-Ordner, /opt/... Prefix etc.).

REPO_DEFAULT="jkef80/jkef-bot-updates"
INSTALL_DIR="/opt/jkef-trading-bot"
GH_ENV="/etc/jkef-trading-bot/github.env"

say() { printf "%s\n" "$*"; }
err() { printf "ERROR: %s\n" "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }

run_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    sudo -n true 2>/dev/null || {
      say ""; say "== sudo benötigt (Root-Rechte) =="; say "Bitte Passwort eingeben, falls gefragt."; say "";
    }
    sudo "$@"
  else
    "$@"
  fi
}

invoker_user() {
  # User, der das Script gestartet hat (nicht root)
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  else
    echo "${USER:-admin}"
  fi
}

install_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    say "Installiere Paket: jq …"
    run_root apt-get update -y
    run_root apt-get install -y jq
  fi
}

read_token() {
  say ""; say "GitHub Updates-Repo [${REPO_DEFAULT}]:"; say ""
  say ""; say "============================================================"
  say "Gib jetzt deinen GitHub Token ein (Eingabe bleibt unsichtbar)."
  say "WICHTIG: Danach ENTER drücken."
  say "============================================================"
  read -rs -p "Token: " GH_TOKEN < /dev/tty
  echo "" > /dev/tty

  if [[ -z "${GH_TOKEN}" ]]; then
    err "Kein Token eingegeben."; exit 1
  fi

  run_root mkdir -p "$(dirname "$GH_ENV")"
  umask 077
  run_root bash -c "cat > '$GH_ENV' <<EOF\nJKEF_GH_TOKEN='${GH_TOKEN}'\nJKEF_GH_REPO='${REPO_DEFAULT}'\nEOF"
  run_root chmod 600 "$GH_ENV"
  say "GitHub-Zugang gespeichert: $GH_ENV (600)"
}

api() {
  local method="$1" url="$2"; shift 2
  # shellcheck disable=SC2086
  curl -fsSL -X "$method" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url" "$@"
}

latest_release_json() {
  api GET "https://api.github.com/repos/${REPO_DEFAULT}/releases/latest"
}

pick_asset() {
  local json="$1"
  # bevorzugt: tar.gz mit jkef-trading-bot im Namen
  local name
  name=$(jq -r '.assets[] | select(.name|test("jkef-trading-bot")) | select(.name|endswith(".tar.gz")) | .name' <<<"$json" | head -n1 || true)
  if [[ -z "$name" ]]; then
    # fallback: erstes tar.gz
    name=$(jq -r '.assets[] | select(.name|endswith(".tar.gz")) | .name' <<<"$json" | head -n1 || true)
  fi
  echo "$name"
}

asset_id_for_name() {
  local json="$1" name="$2"
  jq -r --arg NAME "$name" '.assets[] | select(.name==$NAME) | .id' <<<"$json"
}

download_asset() {
  local asset_id="$1" out="$2"
  # Asset-Download über API (redirects) -> setzt richtige Auth
  api GET "https://api.github.com/repos/${REPO_DEFAULT}/releases/assets/${asset_id}" \
    -H "Accept: application/octet-stream" \
    -o "$out"
}

# Detect how many path components to strip when extracting.
# - If archive paths start with "opt/jkef-trading-bot/" -> strip 2
# - If they start with a single common top folder -> strip 1
# - Else -> strip 0
compute_strip_components() {
  local tarfile="$1"
  local paths
  paths=$(tar -tzf "$tarfile" | head -n 200)
  [[ -n "$paths" ]] || { echo 0; return; }

  # If any path begins with opt/jkef-trading-bot/
  if grep -qE '^opt/jkef-trading-bot/' <<<"$paths"; then
    echo 2; return
  fi

  # Determine common first component
  local first
  first=$(awk -F/ 'NF{print $1}' <<<"$paths" | grep -v '^\.$' | sort -u | head -n2)
  if [[ $(wc -l <<<"$first") -eq 1 ]]; then
    # Exactly one unique top component
    echo 1; return
  fi

  echo 0
}

safe_deploy_tree() {
  local tarfile="$1" target="$2" owner="$3"
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  local strip
  strip=$(compute_strip_components "$tarfile")

  say "Entpacke (strip-components=$strip) nach Staging …"
  tar -xzf "$tarfile" -C "$tmp" --strip-components="$strip"

  # Sanity: muss install.sh enthalten
  if [[ ! -f "$tmp/install.sh" ]]; then
    err "Im Paket fehlt install.sh (nach Entpacken)."
    err "TAR-Top-Level (debug):"
    tar -tzf "$tarfile" | head -n 30 >&2
    exit 1
  fi

  # Zusätzliche Sanity: app/main.py ist Pflicht (sonst Installation abbrechen, damit /opt nicht leer/kaputt wird)
  if [[ ! -f "$tmp/app/main.py" ]]; then
    err "Source tree ist unvollständig (./app/main.py fehlt)."
    err "Abbruch, um ein Löschen der Installation zu verhindern."
    err "Enthaltene Dateien (Top-Level):"
    (cd "$tmp" && ls -la) >&2
    exit 1
  fi

  say "Deploy nach $target …"
  run_root mkdir -p "$target"
  run_root rsync -a --delete \
    --exclude='.env' \
    --exclude='config.json' \
    --exclude='data/' \
    "$tmp/" "$target/"

  # Ownership so setzen, dass der Invoker/Service-User schreiben kann (venv!)
  run_root chown -R "$owner:$owner" "$target"
  run_root find "$target" -type d -exec chmod 755 {} +
  run_root find "$target" -type f -exec chmod 644 {} +
  run_root chmod +x "$target/install.sh" || true
}

main() {
  say "== JKEF Bootstrap Installer =="
  install_jq
  need curl
  need tar
  need rsync

  local owner
  owner=$(invoker_user)

  if [[ ! -f "$GH_ENV" ]]; then
    read_token
  else
    # load token
    # shellcheck disable=SC1090
    source "$GH_ENV"
    GH_TOKEN="${JKEF_GH_TOKEN:-}"
    if [[ -z "${GH_TOKEN}" ]]; then
      read_token
    else
      say "GitHub-Zugang geladen: $GH_ENV"
    fi
  fi

  say "Hole Latest Release von GitHub …"
  local json
  json=$(latest_release_json)
  local tag
  tag=$(jq -r '.tag_name // ""' <<<"$json")
  local asset
  asset=$(pick_asset "$json")
  if [[ -z "$asset" ]]; then
    err "Kein .tar.gz Asset im Latest Release gefunden."; exit 1
  fi
  say "Gefundenes Release: ${tag}"
  say "Gefundenes Asset:   ${asset}"

  local id
  id=$(asset_id_for_name "$json" "$asset")
  if [[ -z "$id" || "$id" == "null" ]]; then
    err "Konnte Asset-ID nicht ermitteln."; exit 1
  fi

  local dl
  dl=$(mktemp)
  trap 'rm -f "$dl"' EXIT

  say "Download (via Asset-ID) …"
  download_asset "$id" "$dl"

  safe_deploy_tree "$dl" "$INSTALL_DIR" "$owner"

  say "Starte Bot-Installer aus $INSTALL_DIR/install.sh …"
  say "Hinweis: Ab jetzt kommen die Abfragen für .env / config.json / Binance Keys etc."

  # Bot-Installer als normaler User ausführen (root nur über sudo IN install.sh)
  run_root bash -c "set -a; source '$GH_ENV'; set +a; exec sudo -u '$owner' -H bash '$INSTALL_DIR/install.sh' < /dev/tty > /dev/tty 2>&1"
}

main "$@"
