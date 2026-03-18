# Icinga2 StartOS Wrapper — Project Instructions

## Overview

Icinga2 monitoring system packaged for StartOS 0.4.0. Deploys Icinga2 + IcingaWeb2 + MySQL in a single LXC subcontainer on haz1upstart003 (10.0.20.87). Syncs host/service definitions from Observium on haz1upmedia001.

## Architecture

- **Observium** (haz1upmedia001) = source of truth for device inventory and check definitions
- **Icinga2** (haz1upstart003) = runs active checks independently, provides better dashboard/visualization
- **Bridge**: `scripts/sync-observium.py` reads Observium MySQL, generates Icinga2 config files
- **No passive checks** — Icinga2 runs all checks itself from its own network vantage point

## Key Patterns

### LXC Compatibility (CRITICAL)
- MySQL runs as `user = root` via `/etc/mysql/mysql.conf.d/lxc-compat.cnf` — LXC namespace mapping breaks mysql user permissions
- `chmod -R 777` on datadir is intentional, not a security issue
- `setcap cap_net_raw+ep` on fping/ping for ICMP without root
- All `chown` calls use `2>/dev/null || true` — they may silently fail in LXC

### Build System
- `docker_entrypoint.sh` is NOT listed in Makefile INGREDIENTS — changes to it don't trigger rebuilds
- **Always `rm -f *.s9pk` before `make`** when entrypoint or scripts change
- Deploy via SCP workaround (see `docs/startos-troubleshooting.md` — start-cli wrapperRepo issue)

### Configuration
- FileHelper pattern for config.yaml
- Passwords (admin, DB, API) auto-generated on first boot in main.ts
- Passed to container via `S9_ICINGA2_*` environment variables
- Container reads config with `get_config()` shell function (yq-based)

### Observium Sync
- Opt-in via config toggle
- Runs every 15 minutes via cron + on-demand via "Sync Now" action
- On-demand uses trigger file (`/root/data/start9/sync-trigger`) checked by cron every minute
- Observium DB schema: uses `probe_disabled` (NOT `probe_deleted`)
- Remote MySQL access: container connects to haz1upmedia001 (10.0.60.125) MySQL directly — WORKING
- 71 devices synced, generating hosts/services/hostgroups in `/etc/icinga2/conf.d/generated/`
- Alternative external sync script: `scripts/sync-observium-to-icinga.py` (uses Icinga2 API, can run from haz1upmedia001)

### ntfy Notifications
- Opt-in via config toggle in Configure Settings action
- When enabled, generates `ntfy-notifications.conf` and `ntfy-apply.conf` at startup
- Notification script: `/usr/local/bin/notify-ntfy.sh` (reads config.yaml for server/topic/auth)
- State filters: configurable per-state toggles (CRITICAL/WARNING/RECOVERY/UNKNOWN)
- Priority mapping: CRITICAL→urgent (5), WARNING→configurable default, OK→default (3)
- Notification policy: check every 5min, retry 3x at 1min intervals, then alert

### Icinga2 API
- Port 5665, binds to 0.0.0.0 inside container
- User: `root`, password: auto-generated (stored in config.yaml as `api-password`)
- Self-signed TLS certificate (CN: icinga2-startos)
- Exposed via StartOS interface `api-multi` but NOT reachable externally (StartOS LXC networking doesn't NAT arbitrary TCP ports)
- Access internally: `start-cli package attach icinga2 -- curl -sk -u root:<api-pass> https://127.0.0.1:5665/v1/status`

### Icinga2 PKI
- Do NOT use `icinga2 api setup` — it generates certs using container hostname (random LXC hash)
- Use `icinga2 pki new-cert --cn icinga2-startos` explicitly
- Cert directory: `/var/lib/icinga2/certs/` (not legacy `/etc/icinga2/pki/`)
- `chmod -R 777 /var/lib/icinga2` before PKI generation (LXC permissions)

### Icinga2 Config
- Clean out default `/etc/icinga2/conf.d/*.conf` BEFORE writing custom templates
- Never redefine `NodeName`/`ZoneName` constants — they're immutable once set in `constants.conf`
- ITL includes 214 built-in CheckCommands (including `snmp-uptime`) — don't create duplicates

## Credentials

Stored in Bitwarden: "haz1upstart003 - Icinga2 IcingaWeb2 Admin"
- Admin: `admin` / auto-generated on first boot
- API: port 5665, user `root`, auto-generated password

## GitHub

- Repo: https://github.com/jeffreymsimon/start9-icinga2_wrapper
- Remote: `git@github.com:jeffreymsimon/start9-icinga2_wrapper.git`

## Deployment

```bash
# Build
rm -f *.s9pk && make

# Deploy (SCP workaround for alpha20)
scp -i ~/bin/claude/.config/ssh/claude-key icinga2.s9pk start9@10.0.20.87:/tmp/
ssh -i ~/bin/claude/.config/ssh/claude-key start9@10.0.20.87 \
  "sudo start-cli package install --sideload /tmp/icinga2.s9pk"
```

## Debugging

```bash
# View logs
ssh -i ~/bin/claude/.config/ssh/claude-key start9@10.0.20.87 \
  "sudo journalctl -u 'startd' --since '5 min ago' | grep icinga2"

# Attach to container
ssh -i ~/bin/claude/.config/ssh/claude-key start9@10.0.20.87 \
  "sudo start-cli package attach icinga2 -- /bin/bash"

# Inside container:
supervisorctl status                    # Check all processes
cat /var/log/supervisor/icinga2-err.log # Icinga2 errors
icinga2 daemon -C                       # Validate config
mysql -u root icinga2_ido -e "SELECT count(*) FROM icinga_hosts;"
```
