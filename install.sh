#!/bin/bash

# =============================================================================
# LXC Update Script Installer
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PATH="/usr/bin/lxc-update"
CONFIG_DIR="/etc/lxc-update"

echo "Installing LXC Update Script..."

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Install the main script
echo "  Installing script to $INSTALL_PATH"
cp "$SCRIPT_DIR/update.sh" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

# Create config directory
echo "  Creating config directory $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

# Copy example exclude file if no exclude list exists
if [[ ! -f "$CONFIG_DIR/exclude.list" ]]; then
    echo "  Creating empty exclude.list"
    cp "$SCRIPT_DIR/exclude.list.example" "$CONFIG_DIR/exclude.list"
fi

# Create log directory
echo "  Creating log directory /var/log/lxc-update"
mkdir -p /var/log/lxc-update

echo ""
echo "Installation complete!"
echo ""
echo "Usage:"
echo "  lxc-update              Run the update script"
echo ""
echo "Configuration:"
echo "  $CONFIG_DIR/exclude.list    Add CTIDs to skip (one per line)"
echo ""
echo "Logs:"
echo "  /var/log/lxc-update/        Daily log files"
