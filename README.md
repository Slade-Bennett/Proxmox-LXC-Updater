# LXC Container Update Script

A bash script for automating package updates across all LXC containers on a Proxmox VE host.

## Features

- Automatically updates all LXC containers with `apt-get`
- Handles stopped containers (starts them, updates, then stops)
- Prevents concurrent runs with lock file protection
- Pre-flight internet connectivity check
- Excludable container list
- Color-coded output with progress indicators
- Daily log files for audit trail

## Requirements

- Proxmox VE host
- Root access
- Debian/Ubuntu-based LXC containers (uses `apt-get`)

## Installation

1. Copy the script to your Proxmox host:
   ```bash
   scp update.sh root@proxmox:/usr/local/bin/lxc-update.sh
   ```

2. Make it executable:
   ```bash
   chmod +x /usr/local/bin/lxc-update.sh
   ```

## Usage

Run manually:
```bash
./lxc-update.sh
```

### Scheduled Updates (Cron)

Add to root's crontab for automatic weekly updates:
```bash
crontab -e
```

```cron
# Run every Sunday at 3:00 AM
0 3 * * 0 /usr/local/bin/lxc-update.sh >> /var/log/lxc-update/cron.log 2>&1
```

## Configuration

### Excluding Containers

Edit the `EXCLUDE_LIST` variable at the top of the script to skip specific containers:

```bash
EXCLUDE_LIST="100 105 110"  # Space-separated CTIDs to skip
```

### Log Directory

Logs are stored in `/var/log/lxc-update/` with daily rotation by filename (`YYYY-MM-DD.log`).

## How It Works

1. Checks for existing lock file to prevent concurrent runs
2. Verifies internet connectivity via ping to `8.8.8.8`
3. Retrieves list of all containers using `pct list`
4. For each container:
   - Skips if in exclude list
   - Starts container if stopped (remembers original state)
   - Runs `apt-get update`
   - Runs `apt-get upgrade -y`
   - Runs `apt-get autoremove -y`
   - Restores original stopped state if applicable
5. Logs all output with timestamps

## Output Example

```
📦 Starting LXC updates: Wed Jan 28 10:00:00 UTC 2026

🔧 Updating container 100
🔄 Progress: 0%
🔄 Progress: 25%
🔄 Progress: 50%
🔄 Progress: 75%
✅ Progress: 100%
✅ Finished container 100

✅ All containers updated: Wed Jan 28 10:05:00 UTC 2026
```

## Limitations

- Only supports Debian/Ubuntu containers (apt-based)
- Requires containers to have network access
- No parallel execution (updates containers sequentially)

## Files

| Path | Description |
|------|-------------|
| `/var/log/lxc-update/` | Log directory |
| `/tmp/lxc-update.lock` | Lock file (auto-cleaned) |

## License

MIT