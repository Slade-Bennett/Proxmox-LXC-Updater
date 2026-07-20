#!/bin/bash

# =============================================================================
# LXC Container Update Script
# Automatically updates all Proxmox LXC containers, detecting apt, dnf, or
# yum per-container at runtime
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Configuration (override via environment variables)
# -----------------------------------------------------------------------------

LOGDIR="${LXC_UPDATE_LOGDIR:-/var/log/lxc-update}"
LOCKFILE="${LXC_UPDATE_LOCKFILE:-/tmp/lxc-update.lock}"
EXCLUDE_FILE="${LXC_UPDATE_EXCLUDE_FILE:-/etc/lxc-update/exclude.list}"
LOG_RETENTION_DAYS="${LXC_UPDATE_LOG_RETENTION_DAYS:-30}"
CONTAINER_TIMEOUT="${LXC_UPDATE_CONTAINER_TIMEOUT:-600}" # seconds, per package manager step

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
    echo "                          or updating packages."
    echo "  -h, --help              Show this help message."
    echo ""
    echo "Package manager (apt, dnf, or yum) is auto-detected per container - no"
    echo "configuration needed."
    echo ""
    echo "Environment variable overrides (mainly useful for testing):"
    echo "  LXC_UPDATE_LOGDIR               Default: /var/log/lxc-update"
    echo "  LXC_UPDATE_LOCKFILE             Default: /tmp/lxc-update.lock"
    echo "  LXC_UPDATE_EXCLUDE_FILE         Default: /etc/lxc-update/exclude.list"
    echo "  LXC_UPDATE_LOG_RETENTION_DAYS   Default: 30"
    echo "  LXC_UPDATE_CONTAINER_TIMEOUT    Default: 600 (seconds per package manager step)"
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

# Detect which package manager is available inside a container. Checked by
# what's actually present (via `command -v`) rather than inferred from an
# OS name/ID, so it stays correct even if a container's OS ever changes.
# dnf is checked before yum since RHEL8+/Fedora/Rocky/Alma often keep a yum
# shim around for compatibility after migrating to dnf.
detect_pkg_mgr() {
    local ctid=$1
    if pct exec "$ctid" -- command -v dnf &>/dev/null; then
        echo dnf
    elif pct exec "$ctid" -- command -v yum &>/dev/null; then
        echo yum
    elif pct exec "$ctid" -- command -v apt-get &>/dev/null; then
        echo apt
    else
        echo unknown
    fi
}

# Runs a single command inside a container, bounded by a timeout so one
# hung container can't block the whole run.
run_in_container() {
    local ctid=$1
    shift
    timeout "$CONTAINER_TIMEOUT" pct exec "$ctid" -- "$@"
}

# Refresh + upgrade + cleanup for a container, dispatched by package manager.
# Sets UPDATE_FAIL_STAGE so the caller can log which step failed.
# Returns: 0 success, 1 fatal failure (update/upgrade), 2 cleanup-only failure
# (autoremove) which is logged as a warning but not treated as an overall
# failure, matching the original apt-only behavior.
UPDATE_FAIL_STAGE=""

update_container_packages() {
    local ctid=$1
    local pkg_mgr=$2

    case "$pkg_mgr" in
        apt)
            if ! run_in_container "$ctid" env DEBIAN_FRONTEND=noninteractive \
                apt-get update -qq -o Dpkg::Options::="--force-confold"; then
                UPDATE_FAIL_STAGE="update"
                return 1
            fi
            if ! run_in_container "$ctid" env DEBIAN_FRONTEND=noninteractive \
                apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold"; then
                UPDATE_FAIL_STAGE="upgrade"
                return 1
            fi
            if ! run_in_container "$ctid" env DEBIAN_FRONTEND=noninteractive \
                apt-get autoremove -y -qq -o Dpkg::Options::="--force-confold"; then
                UPDATE_FAIL_STAGE="autoremove"
                return 2
            fi
            ;;
        dnf)
            # dnf refreshes metadata and upgrades in one step - no separate
            # "update" phase like apt has.
            if ! run_in_container "$ctid" dnf upgrade -y -q; then
                UPDATE_FAIL_STAGE="upgrade"
                return 1
            fi
            if ! run_in_container "$ctid" dnf autoremove -y -q; then
                UPDATE_FAIL_STAGE="autoremove"
                return 2
            fi
            ;;
        yum)
            if ! run_in_container "$ctid" yum update -y -q; then
                UPDATE_FAIL_STAGE="update"
                return 1
            fi
            # autoremove may not exist on older yum (RHEL7-era) - treated the
            # same as apt's cleanup step: non-fatal if it fails.
            if ! run_in_container "$ctid" yum autoremove -y -q; then
                UPDATE_FAIL_STAGE="autoremove"
                return 2
            fi
            ;;
        *)
            UPDATE_FAIL_STAGE="detect"
            return 1
            ;;
    esac

    return 0
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
# Membership is checked as a space-padded substring glob match, e.g.
# " 100 105 " == *" 100 "* — treats CTID as a literal string, not a pattern.
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
    if [[ ${#TARGET_CONTAINERS[@]} -eq 0 ]] && [[ " $EXCLUDE_LIST " == *" $CTID "* ]]; then
        log_warn "Skipping container $CTID (excluded)"
        ((SKIPPED++))
        continue
    fi

    echo ""
    log_info "Updating container $CTID..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would start (if stopped), detect package manager, update/upgrade/autoremove, then restore original state for $CTID"
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

    # Detect package manager (apt, dnf, or yum) present in this container
    PKG_MGR=$(detect_pkg_mgr "$CTID")
    if [[ "$PKG_MGR" == "unknown" ]]; then
        log_error "Could not detect a supported package manager on $CTID (looked for dnf, yum, apt-get)"
        ((FAILED++))
        [[ "$WAS_STOPPED" == true ]] && pct stop "$CTID" &>/dev/null
        continue
    fi

    update_container_packages "$CTID" "$PKG_MGR" &>> "$LOGFILE"
    RESULT=$?

    if [[ "$RESULT" -eq 1 ]]; then
        log_error "Failed package $UPDATE_FAIL_STAGE on $CTID ($PKG_MGR)"
        ((FAILED++))
        [[ "$WAS_STOPPED" == true ]] && pct stop "$CTID" &>/dev/null
        continue
    elif [[ "$RESULT" -eq 2 ]]; then
        log_warn "Package $UPDATE_FAIL_STAGE failed on $CTID ($PKG_MGR) - update/upgrade still succeeded"
    fi

    log_success "Finished container $CTID ($PKG_MGR)"
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
