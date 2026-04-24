#!/bin/bash
# ============================================================
# Add swap space — recommended for t2.micro (1 GB RAM).
# Run once after bootstrap if memory pressure is observed.
# Usage: sudo ./scripts/add-swap.sh [SIZE_GB]
# Default size: 2 GB
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] $*${NC}"; }

[[ "${EUID}" -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

SIZE_GB="${1:-2}"
SWAP_FILE="/swapfile"

if swapon --show | grep -q "${SWAP_FILE}"; then
  warn "Swap already active on ${SWAP_FILE}:"
  swapon --show
  exit 0
fi

log "Creating ${SIZE_GB}GB swap at ${SWAP_FILE}..."
fallocate -l "${SIZE_GB}G" "${SWAP_FILE}"
chmod 600 "${SWAP_FILE}"
mkswap "${SWAP_FILE}"
swapon "${SWAP_FILE}"

# Persist across reboots
if ! grep -q "${SWAP_FILE}" /etc/fstab; then
  echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
  log "Added to /etc/fstab"
fi

# Tune swappiness — prefer RAM, use swap only under pressure
sysctl vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.d/99-zerogate.conf

log "Swap enabled:"
swapon --show
free -h
