#!/bin/bash

# =============================================================================
# LXC Container Update Script
# Automatically updates all Proxmox LXC containers with apt-get
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

LOGDIR="/var/log/lxc-update"
LOCKFILE="/tmp/lxc-update.lock"
EXCLUDE_FILE="/etc/lxc-update/exclude.list"
LOG_RETENTION_DAYS=30

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log_info()    { echo -e "${BLUE}$1${NC}" | tee -a "$LOGFILE"; }
log_success() { echo -e "${GREEN}$1${NC}" | tee -a "$LOGFILE"; }
log_warn()    { echo -e "${YELLOW}$1${NC}" | tee -a "$LOGFILE"; }
log_error()   { echo -e "${RED}$1${NC}" | tee -a "$LOGFILE"; }

wait_for_container() {
    local ctid=$1
    local max_attempts=10
    for ((i=1; i<=max_attempts; i++)); do
        pct exec "$ctid" -- true 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

# -----------------------------------------------------------------------------
# Initialization
# -----------------------------------------------------------------------------

# Create log directory and set up log file
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/$(date +%F).log"

# Clean up old logs
find "$LOGDIR" -name "*.log" -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null

# Load exclude list from file (one CTID per line, # for comments)
EXCLUDE_LIST=""
if [[ -f "$EXCLUDE_FILE" ]]; then
    EXCLUDE_LIST=$(grep -v '^#' "$EXCLUDE_FILE" | grep -v '^$' | tr '\n' ' ')
fi

# Acquire exclusive lock (prevents concurrent runs)
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo -e "${YELLOW}Update already in progress.${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------

if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
    log_error "No internet connection."
    exit 1
fi

# -----------------------------------------------------------------------------
# Main Update Loop
# -----------------------------------------------------------------------------

log_info "Starting LXC updates: $(date)"

CTIDS=$(pct list | awk 'NR>1 {print $1}')
SUCCESS=0
FAILED=0
SKIPPED=0

for CTID in $CTIDS; do
    # Check exclusion list
    if [[ " $EXCLUDE_LIST " =~ " $CTID " ]]; then
        log_warn "Skipping container $CTID (excluded)"
        ((SKIPPED++))
        continue
    fi

    echo ""
    log_info "Updating container $CTID..."

    # Start container if stopped
    WAS_STOPPED=false
    if ! pct status "$CTID" | grep -q running; then
        pct start "$CTID" &>/dev/null
        WAS_STOPPED=true

        if ! wait_for_container "$CTID"; then
            log_error "Container $CTID failed to start"
            ((FAILED++))
            continue
        fi
    fi

    # Run apt update
    if ! pct exec "$CTID" -- apt-get update -qq &>> "$LOGFILE"; then
        log_error "Failed apt update on $CTID"
        ((FAILED++))
        [[ "$WAS_STOPPED" == true ]] && pct stop "$CTID" &>/dev/null
        continue
    fi

    # Run apt upgrade
    if ! pct exec "$CTID" -- apt-get upgrade -y -qq &>> "$LOGFILE"; then
        log_error "Failed apt upgrade on $CTID"
        ((FAILED++))
        [[ "$WAS_STOPPED" == true ]] && pct stop "$CTID" &>/dev/null
        continue
    fi

    # Clean up
    pct exec "$CTID" -- apt-get autoremove -y -qq &>> "$LOGFILE"

    log_success "Finished container $CTID"
    ((SUCCESS++))

    # Restore original state
    if [[ "$WAS_STOPPED" == true ]]; then
        pct stop "$CTID" &>/dev/null
    fi
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo ""
log_success "Update complete: $(date)"
log_info "Results: $SUCCESS succeeded, $FAILED failed, $SKIPPED skipped"
