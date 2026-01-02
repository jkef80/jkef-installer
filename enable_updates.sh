#!/usr/bin/env bash
set -euo pipefail

APP="jkef-trading-bot"
DIR="/etc/jkef-trading-bot"
FILE="$DIR/github.env"
DROPIN_DIR="/etc/systemd/system/${APP}.service.d"
DROPIN_FILE="${DROPIN_DIR}/override.conf"
REPO_DEFAULT="jkef80/jkef-bot-updates"

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte mit sudo ausführen." >&2
  exit 1
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

read -r -p "GitHub Repo [$REPO_DEFAULT]: " REPO </dev/tty || true
REPO="${REPO:-$REPO_DEFAULT}"

read -rsp "GitHub Token (PAT): " TOKEN </dev/tty || true
echo "" >/dev/tty

if [ -z "${TOKEN:-}" ]; then
  echo "Kein Token eingegeben – Abbruch." >&2
  exit 1
fi

umask 077
cat >"$FILE" <<EOF2
JKEF_GH_REPO=$REPO
JKEF_GH_TOKEN=$TOKEN
EOF2
chmod 600 "$FILE"

mkdir -p "$DROPIN_DIR"
cat >"$DROPIN_FILE" <<EOF2
[Service]
EnvironmentFile=-$FILE
EOF2

systemctl daemon-reload
systemctl restart "$APP"

echo "OK ✅ Online-Update aktiv. In der UI: Update → Nach Update suchen"
