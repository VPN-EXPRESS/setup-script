#!/usr/bin/env bash
# =============================================================================
# backup.sh — creates a 3x-ui backup from the remote server and saves it locally
#
# Usage:
#   bash backup.sh <IP>
#   bash backup.sh <IP> -i ~/.ssh/id_rsa
#   SSH_PORT=2222 bash backup.sh <IP>
#   BACKUP_DIR=~/backups bash backup.sh <IP>
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/local_lib.sh
source "$SCRIPT_ROOT/scripts/local_lib.sh"

SERVER_IP="${1:-}"
[[ -z "$SERVER_IP" ]] && die "Specify the IP: bash backup.sh <IP>"
shift

SSH_EXTRA=("$@")
init_ssh_options

BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_ROOT}/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${SERVER_IP}_${TIMESTAMP}.tar.gz"
REMOTE_TMP="/tmp/3xui_backup_${TIMESTAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

XUI_DIR="/root"

# Establish ControlMaster to prompt for credentials only once
info "Connecting to ${SERVER_IP}..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" true

# Copy the helper script to the server and run it
info "Creating an archive on ${SERVER_IP}..."
scp "${SCP_OPTS[@]}" "${SCRIPT_ROOT}/scripts/remote_backup.sh" "${SSH_USER}@${SERVER_IP}:/tmp/remote_backup.sh" \
    || die "Failed to copy remote_backup.sh"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
    "TIMESTAMP=${TIMESTAMP} bash /tmp/remote_backup.sh; rm -f /tmp/remote_backup.sh" \
    || die "Failed to create the archive on the server"

# Download the archive
info "Downloading the archive..."
scp "${SCP_OPTS[@]}" "${SSH_USER}@${SERVER_IP}:${REMOTE_TMP}" "${BACKUP_DIR}/${BACKUP_NAME}"

info "Removing the temporary file on the server..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "rm -f ${REMOTE_TMP}"

echo
success "Backup saved: ${BACKUP_DIR}/${BACKUP_NAME}"
ls -lh "${BACKUP_DIR}/${BACKUP_NAME}"
