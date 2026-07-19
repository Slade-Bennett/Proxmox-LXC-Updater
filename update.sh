#!/bin/bash

# =============================================================================
# LXC Container Update Script
# Automatically updates all Proxmox LXC containers with apt-get
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Configuration (override via environment variables)
# -----------------------------------------------------------------------------

LOGDIR="${LXC_UPDATE_LOGDIR:-/var/log/lxc-update}"
LOCKFILE="${LXC_UPDATE_LOCKFILE:-/tmp/lxc-update.lock}"
EXCLUDE_FILE="${LXC_UPDATE_EXCLUDE_FILE:-/etc/lxc-update/exclude.list}"
LOG_RETENTION_DAYS="${LXC_UPDATE_LOG_RETENTION_DAYS:-30}"
CONTAINER_TIMEOUT="${LXC_UPDATE_CONTAINER_TIMEOUT:-600}" # seconds, per apt-get step

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# CLI Arguments
# -----------------------------------------------------------------------------

DRY_RUN=false
declare -a TARGET_CONTAINERS=()

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --container <CTID>  Update only this container. Repeatable or comma-separated"
    echo "                          (e.g. -c 100,105 or -c 100 -c 105). Bypasses the exclude list,"
    echo "                          since an explicit target is an explicit request."
    echo "  -n, --dry-run           Show what would happen without starting/stopping containers"
    echo "                          or running apt-get."
    echo "  -h, --help              Show this help message."
    echo ""
    echo "Environment variable overrides (mainly useful for testing):"
    echo "  LXC_UPDATE_LOGDIR               Default: /var/log/lxc-update"
    echo "  LXC_UPDATE_LOCKFILE             Default: /tmp/lxc-update.lock"
    echo "  LXC_UPDATE_EXCLUDE_FILE         Default: /etc/lxc-update/exclude.list"
    echo "  LXC_UPDATE_LOG_RETENTION_DAYS   Default: 30"
    echo "  LXC_UPDATE_CONTAINER_TIMEOUT    Default: 600 (seconds per apt-get step)"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--container)
            IFS=',' read -ra _ctids <<< "$2"
            TARGET_CONTAINERS+=("${_ctids[@]}")
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo ""
            usage
            ;;
    esac
done

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

# apt-get wrapper: noninteractive, keeps existing conffiles on conflict, and
# bounded by a timeout so one hung container can't block the whole run.
run_apt() {
    local ctid=$1
    shift
    timeout "$CONTAINER_TIMEOUT" pct exec "$ctid" -- env DEBIAN_FRONTEND=noninteractive \
        apt-get "$@" -o Dpkg::Options::="--force-confold"
}

# -----------------------------------------------------------------------------
# Initialization
# -----------------------------------------------------------------------------

# Create log directory and set up log file
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/$(date +%F).log"

# Clean up old logs
find "$LOGDIR" -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null

# Load exclude list from file (one CTID per line, # for comments)
# Membership is checked as a space-padded substring match, e.g.
# " 100 105 " =~ " 100 " — safe here since CTIDs are always plain integers
# with no regex metacharacters.
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

if [[ "$DRY_RUN" == true ]]; then
    log_warn "Dry run - no containers will actually be started, stopped, or updated."
fi

log_info "Starting LXC updates: $(date)"

if [[ ${#TARGET_CONTAINERS[@]} -gt 0 ]]; then
    CTIDS="${TARGET_CONTAINERS[*]}"
    log_info "Targeting explicitly requested container(s): $CTIDS (exclude list ignored)"
else
    CTIDS=$(pct list | awk 'NR>1 {print $1}')
fi

SUCCESS=0
FAILED=0
SKIPPED=0

for CTID in $CTIDS; do
    # Exclude list only applies when no explicit -c/--container targets were given
    if [[ ${#TARGET_CONTAINERS[@]} -eq 0 ]] && [[ " $EXCLUDE_LIST " =~ " $CTID " ]]; then
        log_warn "Skipping container $CTID (excluded)"
        ((SKIPPED++))
        continue
    fi

    echo ""
    log_info "Updating container $CTID..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would start (if stopped), apt-get update/upgrade/autoremove, then restore original state for $CTID"
        ((SUCCESS++))
        continue
    fi

    # Start container if stopped
    WAS_STOPPED=false
    if ! pct status "$CTID" | grep -q running; then
        pct start "$CTID" &>/dev/null
        WAS_STOPPED=true

        if ! wait_for_container "$CTID"; then
            log_error "Container $CTID failed to start"
            ((FAILED++))
            # Restore state even on a failed start attempt - pct start may have
            # partially succeeded even though the readiness check timed out.
            [[ "$WAS_STOPPED" == true ]] && pct stop "$CTID" &>/dev/null
            continue
        fi
    fi

    # Run apt update
    if ! run_apt "$CTID" update -qq &>> "$LOGFILE"; then
        log_error "Failed apt update on $CTID"
        ((FAILED++))
        [[ "$WAS_STOPPED" == true ]] && pct stop "$CTID" &>/dev/null
        continue
    fi

    # Run apt upgrade
    if ! run_apt "$CTID" upgrade -y -qq &>> "$LOGFILE"; then
        log_error "Failed apt upgrade on $CTID"
        ((FAILED++))
        [[ "$WAS_STOPPED" == true ]] && pct stop "$CTID" &>/dev/null
        continue
    fi

    # Clean up (non-fatal if this fails, but worth flagging rather than
    # silently reporting the container as fully successful)
    if ! run_apt "$CTID" autoremove -y -qq &>> "$LOGFILE"; then
        log_warn "apt autoremove failed on $CTID (update/upgrade still succeeded)"
    fi

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

[[ "$FAILED" -eq 0 ]]
