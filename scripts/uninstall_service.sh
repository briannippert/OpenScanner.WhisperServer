#!/bin/bash
set -e

# =====================================================
# OpenScanner WhisperServer Uninstaller
# =====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_step() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }
log_success() { echo -e "${GREEN}[OK] $1${NC}"; }

if [ "$EUID" -eq 0 ]; then
  echo -e "${RED}[ERROR]${NC} Please run as a regular user (NOT root)."
  exit 1
fi

log_step "Stopping service..."
if systemctl is-active --quiet openscanner-whisper; then
    sudo systemctl stop openscanner-whisper
    log_info "Service stopped."
fi

log_step "Disabling service..."
if systemctl is-enabled --quiet openscanner-whisper 2>/dev/null; then
    sudo systemctl disable openscanner-whisper
    log_info "Service disabled."
fi

log_step "Removing service file..."
if [ -f /etc/systemd/system/openscanner-whisper.service ]; then
    sudo rm /etc/systemd/system/openscanner-whisper.service
    sudo systemctl daemon-reload
    log_info "Service file removed."
fi

echo ""
log_success "OpenScanner WhisperServer service uninstalled."
log_info "Project files have not been removed. Delete manually if desired."
