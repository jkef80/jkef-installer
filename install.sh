#!/usr/bin/env bash
set -euo pipefail

echo "== JKEF Installer =="

# 1) Tools check
need() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1"; exit 1; }; }
need curl
need tar

# 2) Ask for GitHub token (private updates repo)
read -rp "GitHub Repo (default jkef80/jkef-bot-updates): " JKEF_GH_REPO
JKEF_GH_REPO="${JKEF_GH_REPO:-jkef80/jkef-bot-updates}"

read -rsp "GitHub Token (private repo access): " JKEF_GH_TOKEN
echo
if [ -z "${JKEF_GH_TOKEN}" ]; then
  echo "Kein Token eingegeben. Abbruch."
  exit 1
fi

# 3) Save token for later updates
sudo mkdir -p /etc/jkef-trading-bot
sudo bash -c "cat > /etc/jkef-trading-bot/github.env" <<EOF
JKEF_GH_REPO=${JKEF_GH_REPO}
JKEF_GH_TOKEN=${JKEF_GH_TOKEN}
EOF
sudo chmod 600 /etc/jkef-trading-bot/github.env

echo "Token gespeichert in /etc/jkef-trading-bot/github.env (600)."

# 4) Download latest release asset (placeholder)
echo "Nächster Schritt: Download latest Release + ausführen (kommt als nächstes)."
echo "Fertig."
