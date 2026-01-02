#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="jkef80"
REPO_NAME="jkef-bot-updates"
REPO="${REPO_OWNER}/${REPO_NAME}"

GH_ENV="/etc/jkef-trading-bot/github.env"

# Wer ist der "normale" User? (nicht root)
INVOCER_USER="${SUDO_USER:-}"
if [[ -z "${INVOCER_USER}" || "${INVOCER_USER}" == "root" ]]; then
  INVOCER_USER="${USER:-admin}"
fi

HOME_DIR="$(getent passwd "${INVOCER_USER}" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/${INVOCER_USER}}"

say() { printf "%s\n" "$*"; }
die() { printf "FEHLER: %s\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Bitte so starten:  curl -fsSL ... | sudo bash"
  fi
}

install_deps() {
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v jq   >/dev/null 2>&1 || pkgs+=(jq)
  command -v tar  >/dev/null 2>&1 || pkgs+=(tar)

  if ((${#pkgs[@]})); then
    say "Installiere Pakete: ${pkgs[*]} …"
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  fi
}

trim_token() {
  # Entfernt CR/LF und führende/trailing Spaces (Copy&Paste)
  local t="$1"
  t="$(printf "%s" "$t" | tr -d '\r\n')"
  # bash trim spaces
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf "%s" "$t"
}

load_or_ask_token() {
  local token=""

  if [[ -f "${GH_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${GH_ENV}" || true
    token="${JKEF_GH_TOKEN:-}"
  fi

  token="$(trim_token "${token}")"

  if [[ -z "${token}" ]]; then
    say ""
    say "Repo : ${REPO}"
    say "User : ${INVOCER_USER}"
    say "Home : ${HOME_DIR}"
    say ""
    say "============================================================"
    say "Gib jetzt deinen GitHub Token ein (Eingabe bleibt unsichtbar)."
    say "WICHTIG: Danach ENTER drücken."
    say "============================================================"
    read -rs -p "Token: " token < /dev/tty
    echo "" > /dev/tty
    token="$(trim_token "${token}")"
    [[ -n "${token}" ]] || die "Kein Token eingegeben."

    mkdir -p "$(dirname "${GH_ENV}")"
    umask 077
    cat > "${GH_ENV}" <<EOF
JKEF_GH_TOKEN=${token}
EOF
    chmod 600 "${GH_ENV}"
    say "GitHub-Zugang gespeichert: ${GH_ENV} (600)"
  fi

  echo "${token}"
}

http_code() {
  local header="$1" url="$2"
  curl -s -o /dev/null -w "%{http_code}" -H "Accept: application/vnd.github+json" -H "${header}" "${url}" || true
}

detect_auth_header() {
  local token="$1"
  local url="https://api.github.com/user"

  local h1="Authorization: token ${token}"
  local c1; c1="$(http_code "${h1}" "${url}")"
  if [[ "${c1}" == "200" ]]; then
    echo "${h1}"
    return
  fi

  local h2="Authorization: Bearer ${token}"
  local c2; c2="$(http_code "${h2}" "${url}")"
  if [[ "${c2}" == "200" ]]; then
    echo "${h2}"
    return
  fi

  die "Token ungültig (GitHub /user liefert token=${c1}, bearer=${c2}). Bitte neuen Token erzeugen bzw. SSO/Repo-Zugriff prüfen."
}

api_get() {
  local auth="$1" url="$2"
  curl -fsSL -H "Accept: application/vnd.github+json" -H "${auth}" "${url}"
}

download_asset_by_api() {
  local auth="$1" asset_url="$2" out="$3"
  # asset_url ist die API-URL .url (nicht browser_download_url)
  curl -fL \
    -H "${auth}" \
    -H "Accept: application/octet-stream" \
    "${asset_url}" \
    -o "${out}"
}

main() {
  ensure_root
  install_deps

  need curl
  need jq
  need tar

  say "== JKEF Bootstrap Installer (HOME-Extract Mode) =="
  say "Repo : ${REPO}"
  say "User : ${INVOCER_USER}"
  say "Home : ${HOME_DIR}"
  say ""

  local token auth
  token="$(load_or_ask_token)"
  auth="$(detect_auth_header "${token}")"

  say ""
  say "Hole Latest Release von GitHub …"
  local api="https://api.github.com/repos/${REPO}/releases/latest"

  # Falls der Token zwar /user kann, aber nicht aufs Repo -> 404/403 hier
  local release_json
  if ! release_json="$(api_get "${auth}" "${api}")"; then
    die "GitHub Releases API nicht erreichbar oder kein Repo-Zugriff (401/403/404). Wenn /user=200 war, fehlen Repo-Rechte auf ${REPO}."
  fi

  local tag
  tag="$(echo "${release_json}" | jq -r '.tag_name // empty')"
  say "Gefundenes Release: ${tag:-<ohne-tag>}"

  # Erstes .tar.gz Asset nehmen
  local asset_name asset_url
  asset_name="$(echo "${release_json}" | jq -r '.assets[]?.name | select(endswith(".tar.gz"))' | head -n1)"
  [[ -n "${asset_name}" ]] || die "Kein .tar.gz Asset im Latest Release gefunden."

  asset_url="$(echo "${release_json}" | jq -r --arg n "${asset_name}" '.assets[]? | select(.name==$n) | .url')"
  [[ -n "${asset_url}" && "${asset_url}" != "null" ]] || die "Asset API-URL nicht gefunden."

  say "Gefundenes Asset:   ${asset_name}"

  # Download nach HOME (wie gewünscht)
  local stamp base workdir tarfile extractdir
  stamp="$(date +%Y%m%d_%H%M%S)"
  base="${HOME_DIR}/jkef-release_${stamp}"
  workdir="${base}"
  tarfile="${base}/${asset_name}"
  extractdir="${base}/extract"

  mkdir -p "${workdir}"
  chown "${INVOCER_USER}:${INVOCER_USER}" "${workdir}"
  chmod 700 "${workdir}"

  say "Download nach ${tarfile} …"
  download_asset_by_api "${auth}" "${asset_url}" "${tarfile}"
  chown "${INVOCER_USER}:${INVOCER_USER}" "${tarfile}"

  say "Entpacke nach ${extractdir} …"
  mkdir -p "${extractdir}"
  chown "${INVOCER_USER}:${INVOCER_USER}" "${extractdir}"

  # als INVOCER_USER entpacken
  sudo -u "${INVOCER_USER}" tar -xzf "${tarfile}" -C "${extractdir}"

  # Projektordner finden: entweder extract/install.sh oder extract/*/install.sh
  local proj=""
  if [[ -f "${extractdir}/install.sh" ]]; then
    proj="${extractdir}"
  else
    local cand=""
    cand="$(find "${extractdir}" -maxdepth 2 -type f -name install.sh -print -quit || true)"
    if [[ -n "${cand}" ]]; then
      proj="$(dirname "${cand}")"
    fi
  fi
  [[ -n "${proj}" ]] || die "Im entpackten Release wurde keine install.sh gefunden."

  say "Starte Bot-Installer aus: ${proj}/install.sh"
  chmod +x "${proj}/install.sh" || true

  # Bot-Installer soll selbst nach /opt kopieren (so wie du es willst)
  ( cd "${proj}" && bash ./install.sh )

  say ""
  say "== DONE (Bootstrap HOME-Extract) =="
  say "Release-Ordner: ${base}"
}

main "$@"
