#!/usr/bin/env bash
set -euo pipefail

APP_NAME="jkef-trading-bot"
DEFAULT_REPO="jkef80/jkef-bot-updates"

INSTALL_DIR="/opt/${APP_NAME}"
VENV_DIR="${INSTALL_DIR}/.venv"
ENV_FILE="${INSTALL_DIR}/.env"

SERVICE_NAME="${APP_NAME}.service"

NGINX_SITE="/etc/nginx/sites-available/${APP_NAME}"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${APP_NAME}"

SSL_DIR="/etc/ssl/${APP_NAME}"
SSL_CERT="${SSL_DIR}/server.crt"
SSL_KEY="${SSL_DIR}/server.key"

CFG_DIR="/etc/${APP_NAME}"
GH_ENV="${CFG_DIR}/github.env"

# Service-User (wer startet den Bot)
RUN_USER="${SUDO_USER:-$USER}"
RUN_GROUP="$(id -gn "${RUN_USER}" 2>/dev/null || echo "${RUN_USER}")"

WEB_USER_DEFAULT="www-data"
TTY="/dev/tty"; [[ -e "$TTY" ]] || TTY="/dev/stdin"

say(){ echo -e "$*" >"$TTY"; }
die(){ say "Fehler: $*"; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
is_root(){ [ "${EUID:-$(id -u)}" -eq 0 ]; }
run_root(){ if is_root; then "$@"; else sudo "$@"; fi; }

sanitize() {
  local v="${1:-}"
  v="$(printf '%s' "$v" | tr -d '\r\n')"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

prompt() {
  local __var="$1" __text="$2" __default="${3:-}" __val=""
  if [[ -n "$__default" ]]; then
    read -r -p "${__text} [${__default}]: " __val <"$TTY" || true
    __val="${__val:-$__default}"
  else
    read -r -p "${__text}: " __val <"$TTY" || true
  fi
  __val="$(sanitize "$__val")"
  printf -v "${__var}" "%s" "${__val}"
}

prompt_secret() {
  local __var="$1" __text="$2" __val=""
  read -rsp "${__text}: " __val <"$TTY" || true
  echo "" >"$TTY"
  __val="$(sanitize "$__val")"
  printf -v "${__var}" "%s" "${__val}"
}

prompt_yesno() {
  local __var="$1" __text="$2" __default="${3:-y}" __val=""
  read -r -p "${__text} [${__default}]: " __val <"$TTY" || true
  __val="${__val:-$__default}"
  __val="$(echo "${__val}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  [[ "$__val" == "y" || "$__val" == "n" ]] || die "Ungültige Eingabe: ${__val} (bitte y oder n)"
  printf -v "${__var}" "%s" "${__val}"
}

apt_install_if_missing() {
  local pkg="$1" cmd="$2"
  if ! need_cmd "$cmd"; then
    say "Installiere Paket: $pkg …"
    run_root apt-get update -y
    run_root apt-get install -y "$pkg"
  fi
}

install_packages() {
  say ""
  say "Installing required system packages..."
  run_root apt-get update -y
  run_root apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip \
    build-essential \
    nginx openssl ca-certificates \
    curl jq rsync tar
}

write_github_env() {
  run_root mkdir -p "$CFG_DIR"
  run_root chmod 700 "$CFG_DIR"

  local tmp="$(mktemp)"
  cat >"$tmp" <<EOF
JKEF_GH_REPO=${JKEF_GH_REPO}
JKEF_GH_TOKEN=${JKEF_GH_TOKEN}
EOF
  run_root bash -c "cat '$tmp' > '$GH_ENV'"
  run_root chmod 600 "$GH_ENV"
  run_root chown root:root "$GH_ENV" || true
  rm -f "$tmp"
}

download_latest_release_asset() {
  say "Hole Latest Release von GitHub …"
  local api_latest="https://api.github.com/repos/${JKEF_GH_REPO}/releases/latest"

  local release_json
  release_json="$(curl -fsS \
    -H "Authorization: token ${JKEF_GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$api_latest" || true)"

  [[ -n "$release_json" ]] || die "Leere Antwort von GitHub API."

  local msg status
  msg="$(echo "$release_json" | jq -r '.message // empty' 2>/dev/null || true)"
  status="$(echo "$release_json" | jq -r '.status // empty' 2>/dev/null || true)"
  [[ -z "$msg" ]] || die "GitHub API Fehler${status:+ (Status $status)}: $msg"

  TAG_NAME="$(echo "$release_json" | jq -r '.tag_name // empty')"

  ASSET_NAME="$(echo "$release_json" | jq -r '.assets[].name' \
    | grep -E '^jkef-trading-bot_slim_.*\.tar\.gz$' \
    | head -n 1 || true)"
  [[ -n "$ASSET_NAME" ]] || die "Kein passendes Asset gefunden (erwartet jkef-trading-bot_slim_*.tar.gz)."

  ASSET_ID="$(echo "$release_json" | jq -r '.assets[] | select(.name=="'"$ASSET_NAME"'") | .id')"
  [[ -n "$ASSET_ID" && "$ASSET_ID" != "null" ]] || die "Konnte Asset-ID nicht ermitteln."

  say "Release: ${TAG_NAME:-<unbekannt>}"
  say "Asset  : ${ASSET_NAME}"
  say "Download …"

  WORKDIR="$(mktemp -d)"
  ARCHIVE="${WORKDIR}/${ASSET_NAME}"
  EXTRACT_DIR="${WORKDIR}/extract"
  mkdir -p "$EXTRACT_DIR"

  local asset_api="https://api.github.com/repos/${JKEF_GH_REPO}/releases/assets/${ASSET_ID}"
  curl -fL \
    -H "Authorization: token ${JKEF_GH_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -o "$ARCHIVE" \
    "$asset_api"

  [[ -s "$ARCHIVE" ]] || die "Download fehlgeschlagen/leer."

  say "Entpacke nach TEMP …"
  tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"

  if [[ -d "${EXTRACT_DIR}/jkef-trading-bot" ]]; then
    SRC_DIR="${EXTRACT_DIR}/jkef-trading-bot"
  else
    SRC_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  fi

  [[ -n "${SRC_DIR:-}" && -d "$SRC_DIR" ]] || die "Konnte Quellordner im Archiv nicht finden."
}

copy_project_update_safe() {
  say ""
  say "Copying project to ${INSTALL_DIR} (update-safe: keep .env + config.json + data/) …"
  run_root mkdir -p "$INSTALL_DIR"

  local tmp_keep_env="" tmp_keep_cfg="" tmp_keep_data=""

  if [[ -f "$ENV_FILE" ]]; then
    tmp_keep_env="$(mktemp)"
    run_root cp -f "$ENV_FILE" "$tmp_keep_env"
  fi
  if [[ -f "${INSTALL_DIR}/config.json" ]]; then
    tmp_keep_cfg="$(mktemp)"
    run_root cp -f "${INSTALL_DIR}/config.json" "$tmp_keep_cfg"
  fi
  if [[ -d "${INSTALL_DIR}/data" ]]; then
    tmp_keep_data="$(mktemp -d)"
    run_root rsync -a "${INSTALL_DIR}/data/" "${tmp_keep_data}/"
  fi

  run_root rm -rf "${INSTALL_DIR:?}/"*
  run_root rsync -a --delete "${SRC_DIR}/" "${INSTALL_DIR}/"

  if [[ -n "$tmp_keep_env" && -f "$tmp_keep_env" ]]; then
    run_root cp -f "$tmp_keep_env" "$ENV_FILE"
    rm -f "$tmp_keep_env"
  fi
  if [[ -n "$tmp_keep_cfg" && -f "$tmp_keep_cfg" ]]; then
    run_root cp -f "$tmp_keep_cfg" "${INSTALL_DIR}/config.json"
    rm -f "$tmp_keep_cfg"
  fi
  if [[ -n "$tmp_keep_data" && -d "$tmp_keep_data" ]]; then
    run_root mkdir -p "${INSTALL_DIR}/data"
    run_root rsync -a "${tmp_keep_data}/" "${INSTALL_DIR}/data/"
    rm -rf "$tmp_keep_data"
  fi

  run_root chown -R "${RUN_USER}:${RUN_GROUP}" "$INSTALL_DIR"
}

setup_venv() {
  say ""
  say "Creating venv and installing Python deps…"
  run_root -u "${RUN_USER}" python3 -m venv "$VENV_DIR"
  run_root -u "${RUN_USER}" "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools

  if [[ -f "${INSTALL_DIR}/requirements.txt" ]]; then
    run_root -u "${RUN_USER}" "${VENV_DIR}/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"
  else
    run_root -u "${RUN_USER}" "${VENV_DIR}/bin/pip" install \
      "fastapi>=0.110" "uvicorn[standard]>=0.27" "python-dotenv>=1.0" "ccxt>=4.0" "pydantic>=2.0"
  fi

  run_root -u "${RUN_USER}" "${VENV_DIR}/bin/pip" install python-pam six
}

write_env() {
  say ""
  say "Writing .env …"
  run_root mkdir -p "$INSTALL_DIR"
  run_root bash -c "umask 077; : > '$ENV_FILE'"
  run_root bash -c "printf 'BINANCE_API_KEY=%s\n' '${BINANCE_API_KEY}' >> '$ENV_FILE'"
  run_root bash -c "printf 'BINANCE_API_SECRET=%s\n' '${BINANCE_API_SECRET}' >> '$ENV_FILE'"
  run_root bash -c "printf 'HTTP_PORT=%s\n' '${HTTP_PORT}' >> '$ENV_FILE'"
  run_root bash -c "printf 'HTTPS_PORT=%s\n' '${HTTPS_PORT}' >> '$ENV_FILE'"
  run_root bash -c "printf 'JKTRADING_SERVICE=%s\n' '${APP_NAME}' >> '$ENV_FILE'"
  run_root bash -c "printf 'JKTRADING_BOT_ROOT=%s\n' '${INSTALL_DIR}' >> '$ENV_FILE'"

  if [[ "$USE_PAM" == "y" ]]; then
    run_root bash -c "printf 'JKTRADING_PAM_SERVICE=%s\n' '${APP_NAME}' >> '$ENV_FILE'"
    run_root bash -c "printf 'BCHTRADER_PAM_SERVICE=%s\n' '${APP_NAME}' >> '$ENV_FILE'"
  fi

  run_root chmod 600 "$ENV_FILE"
  run_root chown "${RUN_USER}:${RUN_GROUP}" "$ENV_FILE"
}

install_pam_service() {
  [[ "$USE_PAM" == "y" ]] || return 0
  say ""
  say "Configuring PAM service for System-Login (${APP_NAME})…"
  run_root tee "/etc/pam.d/${APP_NAME}" >/dev/null <<'EOF'
@include common-auth
@include common-account
@include common-session
EOF
}

ensure_trade_disabled() {
  local cfg="${INSTALL_DIR}/config.json"
  if [[ ! -f "$cfg" ]]; then
    say "WARN: config.json nicht gefunden unter ${cfg} (überspringe trade_enabled=false)."
    return 0
  fi
  say ""
  say "Ensuring trading.trade_enabled=false in config.json …"
  run_root -u "${RUN_USER}" python3 - <<'PY' "$cfg"
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    cfg = json.load(f)
cfg.setdefault("trading", {})
cfg["trading"]["trade_enabled"] = False
cfg["trade_enabled"] = False
with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
print("OK: trading.trade_enabled=false")
PY
}

ensure_ssl() {
  say ""
  say "Creating self-signed SSL cert (if missing)…"
  run_root mkdir -p "$SSL_DIR"
  if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
    run_root openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$SSL_KEY" -out "$SSL_CERT" \
      -days 3650 \
      -subj "/CN=${APP_NAME}"
    run_root chmod 600 "$SSL_KEY"
    run_root chmod 644 "$SSL_CERT"
  fi
}

install_systemd_service() {
  say ""
  say "Creating systemd service…"

  local PAM_ENV_BLOCK=""
  if [[ "$USE_PAM" == "y" ]]; then
    PAM_ENV_BLOCK="# PAM: erzwinge unseren eigenen PAM-Service
Environment=JKTRADING_PAM_SERVICE=${APP_NAME}
Environment=BCHTRADER_PAM_SERVICE=${APP_NAME}"
    NNP="false"
  else
    NNP="true"
  fi

  run_root tee "/etc/systemd/system/${SERVICE_NAME}" >/dev/null <<EOF
[Unit]
Description=${APP_NAME} (uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}

${PAM_ENV_BLOCK}

ExecStart=${VENV_DIR}/bin/uvicorn app.main:app --host 0.0.0.0 --port \${HTTP_PORT}
Restart=on-failure
RestartSec=3
NoNewPrivileges=${NNP}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  run_root systemctl daemon-reload
  run_root systemctl enable --now "${APP_NAME}"
}

install_nginx() {
  say ""
  say "Configuring nginx (HTTPS -> localhost HTTP)…"

  if [[ -L /etc/nginx/sites-enabled/default ]]; then
    run_root rm -f /etc/nginx/sites-enabled/default
  fi

  run_root tee "$NGINX_SITE" >/dev/null <<EOF
server {
  listen ${HTTPS_PORT} ssl;
  server_name _;

  ssl_certificate     ${SSL_CERT};
  ssl_certificate_key ${SSL_KEY};

  client_max_body_size 50m;

  location / {
    proxy_pass http://127.0.0.1:${HTTP_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
}
EOF

  run_root ln -sf "$NGINX_SITE" "$NGINX_SITE_ENABLED"
  run_root nginx -t
  run_root systemctl restart nginx
}

install_sudoers_for_web() {
  say ""
  say "Installing sudoers rule for Web-UI restart…"
  run_root tee "/etc/sudoers.d/jkef_trading_bot_web" >/dev/null <<EOF
# Allow web user to restart/status the service without password
${WEB_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart ${SERVICE_NAME}, /usr/bin/systemctl is-active ${SERVICE_NAME}, /usr/bin/systemctl status ${SERVICE_NAME}
EOF
  run_root chmod 440 "/etc/sudoers.d/jkef_trading_bot_web"
}

cleanup() {
  [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]] && rm -rf "$WORKDIR" || true
}
trap cleanup EXIT

# ------------------ MAIN ------------------
say "== ${APP_NAME} All-in-one Installer =="
say ""

prompt JKEF_GH_REPO "GitHub Updates-Repo" "${DEFAULT_REPO}"
prompt_secret JKEF_GH_TOKEN "GitHub Token (PAT)"
[[ -n "${JKEF_GH_TOKEN:-}" ]] || die "Kein Token eingegeben."

write_github_env

# Bot-Config Fragen
prompt BINANCE_API_KEY "BINANCE_API_KEY" ""
prompt_secret BINANCE_API_SECRET "BINANCE_API_SECRET"
prompt HTTP_PORT "http-port" "8001"
prompt HTTPS_PORT "https-port" "8002"

say ""
say 'Der "Web-User" ist der Linux-Benutzer, unter dessen Namen'
say 'die Web-Oberfläche den Trading-Bot neu starten darf.'
say ""
prompt WEB_USER "Web-User für Restart via UI" "${WEB_USER_DEFAULT}"
prompt_yesno USE_PAM "System-Login (PAM) für Web-UI nutzen?" "y"

# Systemabhängigkeiten + Download + Install
install_packages
download_latest_release_asset
copy_project_update_safe
setup_venv
write_env
install_pam_service
ensure_trade_disabled
ensure_ssl
install_systemd_service
install_nginx
install_sudoers_for_web

say ""
say "== DONE =="
say "Install dir : ${INSTALL_DIR}"
say "Env file    : ${ENV_FILE}"
say "Service     : ${APP_NAME}  (systemctl status ${APP_NAME})"
say "HTTP        : http://<PI-IP>:${HTTP_PORT}/"
say "HTTPS       : https://<PI-IP>:${HTTPS_PORT}/  (self-signed)"
say ""
say "Logs:"
say "  journalctl -u ${APP_NAME} -f"
