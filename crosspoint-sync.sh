#!/usr/bin/env bash
#
# Proxmox VE helper script - crosspoint-sync
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bastian Kolb
#
# Installer:  https://github.com/Boisti13/pve-crosspoint-sync
# Upstream:   https://github.com/crosspoint-reader/crosspoint-sync (MIT)
#
# This installer is MIT licensed and vendors no upstream code. At install time
# it git-clones crosspoint-sync directly from upstream, which is MIT licensed
# too, so there is no license conflict and nothing is redistributed here.
#
# Creates a Debian 12 LXC and installs crosspoint-sync BAREMETAL inside it
# (Node.js + systemd, no Docker). KOSync-compatible reading-progress sync
# server, purpose-built for CrossPoint/CrossInk firmware (e.g. Xteink X4)
# but also works with plain KOReader.
#
# Run this AS ROOT ON THE PROXMOX VE HOST:
#
#   bash crosspoint-sync.sh
#
# Everything is configurable via environment variables, e.g.:
#
#   CTID=115 MEMORY_MB=768 REGISTRATION_DISABLED=true bash crosspoint-sync.sh
#
# Re-running this script against an existing CTID (CTID=<id> bash crosspoint-sync.sh)
# skips container creation and just re-runs the installer, which is idempotent
# and doubles as the update mechanism. After first install you don't need this
# script again though — just run `pct enter <ctid>` then `update` inside the CT.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Config (override via environment variables)
# ---------------------------------------------------------------------------
CTID="${CTID:-}"
CT_HOSTNAME="${CT_HOSTNAME:-crosspoint-sync}"
DISK_GB="${DISK_GB:-4}"
MEMORY_MB="${MEMORY_MB:-512}"
SWAP_MB="${SWAP_MB:-512}"
CORES="${CORES:-1}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"          # e.g. "192.168.1.50/24,gw=192.168.1.1"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
ONBOOT="${ONBOOT:-1}"

APP_PORT="${APP_PORT:-8080}"
REGISTRATION_DISABLED="${REGISTRATION_DISABLED:-false}"
NODE_MAJOR="${NODE_MAJOR:-24}"
REPO_URL="${REPO_URL:-https://github.com/crosspoint-reader/crosspoint-sync.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

# Where the container re-fetches THIS script from on every `update` run, so the
# in-container `update` and `info` commands stay current instead of being frozen
# at whatever shipped on the day of first install.
INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/Boisti13/pve-crosspoint-sync/master/crosspoint-sync.sh}"

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_INFO="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_RESET="\033[0m"
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_RESET=""
fi
msg_info()  { printf "%b[INFO]%b %s\n"  "$C_INFO" "$C_RESET" "$1"; }
msg_warn()  { printf "%b[WARN]%b %s\n"  "$C_WARN" "$C_RESET" "$1"; }
msg_error() { printf "%b[ERR ]%b %s\n"  "$C_ERR"  "$C_RESET" "$1" >&2; }

trap 'msg_error "Failed at line $LINENO. Aborting."' ERR

# ---------------------------------------------------------------------------
# The installer that runs INSIDE the container. Defined up here so this script
# can also execute it directly in --container-install mode (see below).
# ---------------------------------------------------------------------------
INNER="$(mktemp)"
trap 'rm -f "$INNER"' EXIT

cat > "$INNER" <<'INNER_EOF'
#!/usr/bin/env bash
# crosspoint-sync installer/updater — runs INSIDE the LXC.
# Idempotent: safe to re-run. Installed at /usr/bin/update after first run.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APP_DIR=/opt/crosspoint-sync/app
DATA_DIR=/opt/crosspoint-sync/data
ENV_FILE=/opt/crosspoint-sync/crosspoint-sync.env
SERVICE_NAME=crosspoint-sync

REPO_URL="${REPO_URL:-https://github.com/crosspoint-reader/crosspoint-sync.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
NODE_MAJOR="${NODE_MAJOR:-24}"
INIT_PORT="${APP_PORT:-8080}"
INIT_REGISTRATION_DISABLED="${REGISTRATION_DISABLED:-false}"
INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/Boisti13/pve-crosspoint-sync/master/crosspoint-sync.sh}"
CACHE_INSTALLER=/opt/crosspoint-sync/installer.sh

echo "==> apt-get update && upgrade"
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade

echo "==> Ensuring base packages"
apt-get install -y -qq ca-certificates curl gnupg git

CURRENT_NODE_MAJOR="0"
if command -v node >/dev/null 2>&1; then
  CURRENT_NODE_MAJOR="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
fi
if [ "$CURRENT_NODE_MAJOR" -lt "$NODE_MAJOR" ]; then
  echo "==> Installing Node.js ${NODE_MAJOR}.x (NodeSource)"
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  cat > /etc/apt/sources.list.d/nodesource.sources <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_${NODE_MAJOR}.x/
Suites: nodistro
Components: main
Signed-By: /etc/apt/keyrings/nodesource.gpg
EOF
  apt-get update -qq
  apt-get install -y -qq nodejs
fi

if ! id crosspoint >/dev/null 2>&1; then
  echo "==> Creating service user 'crosspoint'"
  useradd -r -m -d /opt/crosspoint-sync -s /usr/sbin/nologin crosspoint
fi

mkdir -p "$APP_DIR" "$DATA_DIR"

# The checkout ends up owned by the service user, while this installer runs as
# root, so plain git refuses it as "dubious ownership" from the second run on.
# Scope the exemption to this one path instead of touching global git config.
GIT=(git -c "safe.directory=$APP_DIR")

NEED_BUILD=0
if [ -d "$APP_DIR/.git" ]; then
  echo "==> Fetching latest crosspoint-sync ($REPO_BRANCH)"
  "${GIT[@]}" -C "$APP_DIR" fetch --quiet origin "$REPO_BRANCH"
  BEFORE="$("${GIT[@]}" -C "$APP_DIR" rev-parse HEAD)"
  "${GIT[@]}" -C "$APP_DIR" reset --quiet --hard "origin/$REPO_BRANCH"
  AFTER="$("${GIT[@]}" -C "$APP_DIR" rev-parse HEAD)"
  [ "$BEFORE" != "$AFTER" ] && NEED_BUILD=1
else
  echo "==> Cloning crosspoint-sync"
  rm -rf "${APP_DIR:?}"/*
  "${GIT[@]}" clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
  NEED_BUILD=1
fi
[ -d "$APP_DIR/dist" ] || NEED_BUILD=1

if [ "$NEED_BUILD" = "1" ]; then
  echo "==> Building (npm ci && npm run build)"
  cd "$APP_DIR"
  npm ci --no-audit --no-fund
  npm run build
  npm prune --omit=dev
fi

chown -R crosspoint:crosspoint /opt/crosspoint-sync

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Writing $ENV_FILE (edit this to change settings, then: systemctl restart $SERVICE_NAME)"
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=${INIT_PORT}
DATABASE_PATH=${DATA_DIR}/crosspoint.db
REGISTRATION_DISABLED=${INIT_REGISTRATION_DISABLED}
EOF
  chown crosspoint:crosspoint "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

# Render the unit every run and install it only when it actually differs, so
# changes to the unit (paths, hardening, user) reach existing containers too.
# The old "write it only if absent" guard meant a container kept whatever unit
# it was born with, forever.
NEW_UNIT="$(mktemp)"
cat > "$NEW_UNIT" <<EOF
[Unit]
Description=crosspoint-sync (KOSync-compatible sync server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=crosspoint
Group=crosspoint
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/node dist/index.js
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

NEED_RESTART=0
if ! cmp -s "$NEW_UNIT" "/etc/systemd/system/${SERVICE_NAME}.service"; then
  echo "==> Installing/updating systemd unit"
  install -m 644 "$NEW_UNIT" "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  NEED_RESTART=1
fi
rm -f "$NEW_UNIT"
systemctl enable --quiet "$SERVICE_NAME"

if [ "$NEED_BUILD" = "1" ] || [ "${NEED_RESTART:-0}" = "1" ] || ! systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "==> (Re)starting $SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
fi

# Seed/refresh the cached installer. SELF_INSTALLER is set by the host script;
# when `update` runs it instead, the bootstrap below has already refreshed the
# cache, so there is nothing to copy.
mkdir -p "$(dirname "$CACHE_INSTALLER")"
if [ -n "${SELF_INSTALLER:-}" ] && [ -r "${SELF_INSTALLER:-}" ]; then
  install -m 755 "$SELF_INSTALLER" "$CACHE_INSTALLER"
fi

# Install/refresh `update` as a self-updating bootstrap. It re-downloads the
# installer on every run, so `update` and `info` are never frozen at whatever
# shipped on install day. Falls back to the cached copy when offline, and
# refuses to run a download that is empty or not valid bash.
cat > /usr/bin/update <<UPDATE_EOF
#!/usr/bin/env bash
# crosspoint-sync updater. Re-downloads the installer, then runs it.
set -Eeuo pipefail
INSTALLER_URL="\${INSTALLER_URL:-${INSTALLER_URL}}"
CACHE="${CACHE_INSTALLER}"
TMP="\$(mktemp)"
trap 'rm -f "\$TMP"' EXIT

if curl -fsSL --max-time 30 "\$INSTALLER_URL" -o "\$TMP" \
   && [ -s "\$TMP" ] && bash -n "\$TMP" 2>/dev/null; then
  install -m 755 "\$TMP" "\$CACHE"
  echo "==> Installer refreshed from \$INSTALLER_URL"
else
  echo "!! Could not fetch a usable installer from \$INSTALLER_URL"
  if [ ! -x "\$CACHE" ]; then
    echo "!! No cached installer at \$CACHE either — aborting." >&2
    exit 1
  fi
  echo "==> Falling back to the cached installer at \$CACHE"
fi

exec bash "\$CACHE" --container-install
UPDATE_EOF
chmod +x /usr/bin/update

# Install/refresh the info command (prints connection details on demand).
# Named crosspoint-info so it can never clobber texinfo's /usr/bin/info;
# a short `info` alias is linked only when that path is genuinely free.
cat > /usr/bin/crosspoint-info <<'INFO_EOF'
#!/usr/bin/env bash
# crosspoint-sync connection info. Reinstalled on every `update` run.
set -Eeuo pipefail

ENV_FILE=/opt/crosspoint-sync/crosspoint-sync.env
SERVICE_NAME=crosspoint-sync

if [ ! -r "$ENV_FILE" ]; then
  echo "!! Cannot read $ENV_FILE (run as root)" >&2
  exit 1
fi
set -a; . "$ENV_FILE"; set +a

PORT="${PORT:-8080}"
IP_ADDR="$(hostname -I | awk '{print $1}')"
URL="http://${IP_ADDR}:${PORT}"

if systemctl is-active --quiet "$SERVICE_NAME"; then
  STATUS="active (running)"
else
  STATUS="INACTIVE - journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
fi

if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
  HEALTH="ok"
else
  HEALTH="FAILED"
fi

if [ "${REGISTRATION_DISABLED:-false}" = "true" ]; then
  REG="disabled"
else
  REG="enabled"
fi

printf '\n  crosspoint-sync\n\n'
printf '  Sync URL       %s\n' "$URL"
printf '  Service        %s\n' "$STATUS"
printf '  Healthcheck    %s\n' "$HEALTH"
printf '  Registration   %s\n' "$REG"
printf '  Database       %s\n' "${DATABASE_PATH:-unknown}"
printf '  Config         %s\n' "$ENV_FILE"
printf '\n  Enter this URL on your device: %s\n' "$URL"
printf '    CrossPoint/CrossInk   Settings > KOReader Sync > Sync Server URL\n'
printf '    Plain KOReader        Tools > Progress sync > Custom sync server\n\n'
INFO_EOF
chmod +x /usr/bin/crosspoint-info

if [ ! -e /usr/bin/info ] || [ -L /usr/bin/info ]; then
  ln -sfn /usr/bin/crosspoint-info /usr/bin/info
fi

# Read back actual current config for an accurate summary (may have been
# hand-edited by the user since first install).
set -a; source "$ENV_FILE"; set +a

sleep 2
IP_ADDR="$(hostname -I | awk '{print $1}')"
if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
  echo "==> crosspoint-sync is up: http://${IP_ADDR}:${PORT}"
else
  echo "!! Healthcheck failed — check: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
fi
echo "==> Registration disabled: ${REGISTRATION_DISABLED}"
echo "==> Data: ${DATABASE_PATH}"
echo "==> To update later: pct enter <ctid>, then run: update"
echo "==> To see connection details later: run: info"
INNER_EOF

# ---------------------------------------------------------------------------
# In-container mode. /usr/bin/update re-runs this same script with
# --container-install after re-downloading it, so the container picks up the
# newest installer, `update` bootstrap and `info` command every time.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--container-install" ]; then
  chmod +x "$INNER"
  bash "$INNER"
  exit 0
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if ! command -v pveversion >/dev/null 2>&1; then
  msg_error "This doesn't look like a Proxmox VE host (pveversion not found)."
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  msg_error "Run this as root on the Proxmox VE host."
  exit 1
fi

if [ -z "$CTID" ]; then
  CTID="$(pvesh get /cluster/nextid)"
  msg_info "No CTID given, using next free ID: $CTID"
fi

# ---------------------------------------------------------------------------
# Create the container (skipped if CTID already exists)
# ---------------------------------------------------------------------------
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "Container $CTID already exists — skipping creation, will (re)run the installer."
else
  msg_info "Looking for a Debian 12 template..."
  TEMPLATE="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)"
  if [ -z "$TEMPLATE" ]; then
    msg_error "Could not find a debian-12-standard template in 'pveam available'."
    exit 1
  fi
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_info "Downloading template $TEMPLATE to storage '$TEMPLATE_STORAGE'..."
    pveam update >/dev/null
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi

  msg_info "Creating CT $CTID ($CT_HOSTNAME) — ${CORES}c/${MEMORY_MB}MB/${DISK_GB}GB on $ROOTFS_STORAGE"
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --unprivileged "$UNPRIVILEGED" \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap "$SWAP_MB" \
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth" \
    --ostype debian \
    --onboot "$ONBOOT"

  msg_info "Starting CT $CTID..."
  pct start "$CTID"

  msg_info "Waiting for network..."
  for _ in $(seq 1 30); do
    if pct exec "$CTID" -- sh -c "ip -4 addr show eth0 2>/dev/null | grep -q 'inet '"; then
      break
    fi
    sleep 1
  done
fi

if [ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]; then
  msg_info "CT $CTID is not running, starting it..."
  pct start "$CTID"
  sleep 3
fi

# ---------------------------------------------------------------------------
# Push the (idempotent) installer and run it inside the container.
# The installer copies itself to /usr/bin/update, so it also serves as the
# update mechanism from here on — no need to come back to this host script.
# ---------------------------------------------------------------------------

# Resolve a readable copy of THIS script to seed the container's installer
# cache, so `update` has a known-good fallback even with no network. Run via
# the curl one-liner there is no file on disk, so re-fetch it first.
SELF_SRC="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
if [ -z "$SELF_SRC" ] || [ ! -r "$SELF_SRC" ]; then
  msg_info "Running from a pipe - fetching a copy of the installer to cache in the CT..."
  SELF_SRC="$(mktemp)"
  if ! curl -fsSL --max-time 30 "$INSTALLER_URL" -o "$SELF_SRC" || [ ! -s "$SELF_SRC" ]; then
    msg_error "Could not download the installer from $INSTALLER_URL to cache in the container."
    exit 1
  fi
fi

msg_info "Pushing installer into CT $CTID..."
pct push "$CTID" "$INNER" /root/crosspoint-sync-install.sh
pct exec "$CTID" -- chmod +x /root/crosspoint-sync-install.sh
pct push "$CTID" "$SELF_SRC" /root/crosspoint-sync-installer-full.sh

msg_info "Running installer inside CT $CTID (this builds Node from source deps, can take a couple minutes)..."
pct exec "$CTID" -- env \
  APP_PORT="$APP_PORT" \
  REGISTRATION_DISABLED="$REGISTRATION_DISABLED" \
  NODE_MAJOR="$NODE_MAJOR" \
  REPO_URL="$REPO_URL" \
  REPO_BRANCH="$REPO_BRANCH" \
  INSTALLER_URL="$INSTALLER_URL" \
  SELF_INSTALLER=/root/crosspoint-sync-installer-full.sh \
  /root/crosspoint-sync-install.sh

CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"

msg_info "Done. CT $CTID ($CT_HOSTNAME) at ${CT_IP}"
echo

cat <<SUMMARY
Point your devices at:            http://${CT_IP}:${APP_PORT}
  CrossPoint firmware:            Settings -> KOReader Sync -> Sync Server URL
  Plain KOReader:                 Tools -> Progress sync -> Custom sync server

Registration disabled:            ${REGISTRATION_DISABLED}
SUMMARY

if [ "$REGISTRATION_DISABLED" = "false" ]; then
  cat <<WARN

Registration is OPEN — anyone who can reach this container on your LAN can
create an account. Register your devices first, then lock it down with:

  pct exec $CTID -- sed -i 's/REGISTRATION_DISABLED=false/REGISTRATION_DISABLED=true/' /opt/crosspoint-sync/crosspoint-sync.env
  pct exec $CTID -- systemctl restart crosspoint-sync
WARN
fi

cat <<HOWTO

To create an account manually instead of via device registration
(this bypasses REGISTRATION_DISABLED):

  HASH=\$(printf '%s' 'yourpassword' | md5sum | cut -d' ' -f1)
  curl -X POST http://${CT_IP}:${APP_PORT}/users/create \\
    -H 'content-type: application/json' \\
    -d "{\"username\":\"you\",\"password\":\"\$HASH\"}"

To update crosspoint-sync later (pulls latest code, rebuilds, restarts,
also runs apt upgrade):

  pct enter $CTID
  update

The update command re-downloads this installer on every run, so update and
info themselves stay current instead of being frozen at install day. Point
it somewhere else with INSTALLER_URL if you fork this.

To print the sync URL and service status at any time:

  pct enter $CTID
  info
HOWTO
