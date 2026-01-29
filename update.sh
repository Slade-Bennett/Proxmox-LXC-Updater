#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOGDIR="/var/log/lxc-update"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/$(date +%F).log"
LOCKFILE="/tmp/lxc-update.lock"
EXCLUDE_LIST=""  # Space-separated CTIDs to skip

trap "rm -f $LOCKFILE" EXIT

if [ -e "$LOCKFILE" ]; then
  echo -e "${YELLOW}⚠️  Update already in progress.${NC}"
  exit 1
fi
touch "$LOCKFILE"

# Connectivity check
if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
  echo -e "${RED}❌ No internet connection.${NC}" | tee -a "$LOGFILE"
  exit 1
fi

echo -e "${BLUE}📦 Starting LXC updates: $(date)${NC}" | tee "$LOGFILE"
CTIDS=$(pct list | awk 'NR>1 {print $1}')

for CTID in $CTIDS; do
  if [[ " $EXCLUDE_LIST " =~ " $CTID " ]]; then
    echo -e "${YELLOW}⏭️  Skipping container $CTID (excluded)${NC}" | tee -a "$LOGFILE"
    continue
  fi

  echo -e "\n${BLUE}🔧 Updating container $CTID${NC}"
  echo -e "${BLUE}🔄 Progress: 0%${NC}" | tee -a "$LOGFILE"


  WAS_STOPPED=false
  if ! pct status "$CTID" | grep -q running; then
    pct start "$CTID" &>/dev/null
    sleep 2
    WAS_STOPPED=true
  fi

  echo -e "${BLUE}🔄 Progress: 25%${NC}" | tee -a "$LOGFILE"
  if ! pct exec "$CTID" -- apt-get update -qq &>> "$LOGFILE"; then
    echo -e "${RED}❌ Failed apt update on $CTID${NC}" | tee -a "$LOGFILE"
    continue
  fi

  echo -e "${BLUE}🔄 Progress: 50%${NC}" | tee -a "$LOGFILE"
  if ! pct exec "$CTID" -- apt-get upgrade -y -qq &>> "$LOGFILE"; then
    echo -e "${RED}❌ Failed apt upgrade on $CTID${NC}" | tee -a "$LOGFILE"
    continue
  fi

  echo -e "${BLUE}🔄 Progress: 75%${NC}" | tee -a "$LOGFILE"
  pct exec "$CTID" -- apt-get autoremove -y -qq &>> "$LOGFILE"

  echo -e "${GREEN}✅ Progress: 100%${NC}" | tee -a "$LOGFILE"
  echo -e "${GREEN}✅ Finished container $CTID${NC}" | tee -a "$LOGFILE"

  if [ "$WAS_STOPPED" = true ]; then
    pct stop "$CTID" &>/dev/null
  fi
done

echo -e "\n${GREEN}✅ All containers updated: $(date)${NC}" | tee -a "$LOGFILE"