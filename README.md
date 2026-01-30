# LXC Container Update Script

A bash script for automating package updates across all LXC containers on a Proxmox VE host.

## Features

- Automatically updates all LXC containers with `apt-get`
- Handles stopped containers (starts them, updates, then stops)
- Prevents concurrent runs with `flock`-based locking
- Pre-flight internet connectivity check
- External exclude list configuration file
- Automatic log rotation (30-day retention)
- Results summary with success/failure/skipped counts
- Color-coded output

## Requirements

- Proxmox VE host
- Root access
- Debian/Ubuntu-based LXC containers (uses `apt-get`)

## Installation

### Quick Install

Clone the repo to your Proxmox host and run the installer:

```bash
git clone <repo-url> && cd UpdateLXC
chmod +x install.sh
sudo ./install.sh
```

The installer will:
- Copy the script to `/usr/bin/lxc-update`
- Create `/etc/lxc-update/` config directory
- Create an empty exclude list file
- Create the log directory

### Manual Install

1. Copy the script to your Proxmox host:
   ```bash
   scp update.sh root@proxmox:/usr/bin/lxc-update
   chmod +x /usr/bin/lxc-update
   ```

2. Create the config directory:
   ```bash
   mkdir -p /etc/lxc-update
   cp exclude.list.example /etc/lxc-update/exclude.list
   ```

## Usage

Run manually:
```bash
lxc-update
```

### Scheduled Updates (Cron)

Add to root's crontab for automatic weekly updates:
```bash
crontab -e
```

```cron
# Run every Sunday at 3:00 AM
0 3 * * 0 /usr/bin/lxc-update >> /var/log/lxc-update/cron.log 2>&1
```

## Configuration

### Excluding Containers

Edit `/etc/lxc-update/exclude.list` and add one CTID per line:

```
# Lines starting with # are ignored
100
105
110
```

Or use the command line:
```bash
echo "100" >> /etc/lxc-update/exclude.list
```

### Configuration Variables

Edit these variables at the top of the script (`/usr/bin/lxc-update`):

| Variable | Default | Description |
|----------|---------|-------------|
| `LOGDIR` | `/var/log/lxc-update` | Log file directory |
| `LOCKFILE` | `/tmp/lxc-update.lock` | Lock file path |
| `EXCLUDE_FILE` | `/etc/lxc-update/exclude.list` | Exclude list file |
| `LOG_RETENTION_DAYS` | `30` | Days to keep log files |

## How It Works

1. Acquires exclusive lock using `flock` to prevent concurrent runs
2. Cleans up log files older than 30 days
3. Loads exclude list from `/etc/lxc-update/exclude.list`
4. Verifies internet connectivity via ping to `8.8.8.8`
5. Retrieves list of all containers using `pct list`
6. For each container:
   - Skips if in exclude list
   - Starts container if stopped (remembers original state)
   - Waits for container to be ready (up to 10 seconds)
   - Runs `apt-get update`
   - Runs `apt-get upgrade -y`
   - Runs `apt-get autoremove -y`
   - Restores original stopped state if applicable
7. Displays summary with success/failure/skipped counts

## Output Example

```
Starting LXC updates: Wed Jan 28 10:00:00 UTC 2026

Updating container 100...
Finished container 100

Updating container 101...
Finished container 101

Skipping container 105 (excluded)

Update complete: Wed Jan 28 10:05:00 UTC 2026
Results: 2 succeeded, 0 failed, 1 skipped
```

## Limitations

- Only supports Debian/Ubuntu containers (apt-based)
- Requires containers to have network access
- No parallel execution (updates containers sequentially)

## Repository Files

| File | Description |
|------|-------------|
| `update.sh` | Main update script |
| `install.sh` | Installer script |
| `exclude.list.example` | Example exclude list template |

## Installed Files

| Path | Description |
|------|-------------|
| `/usr/bin/lxc-update` | Installed script |
| `/etc/lxc-update/exclude.list` | Container exclusion list |
| `/var/log/lxc-update/` | Log directory |
| `/var/log/lxc-update/YYYY-MM-DD.log` | Daily log files |
| `/tmp/lxc-update.lock` | Lock file (auto-released) |

## License

MIT
