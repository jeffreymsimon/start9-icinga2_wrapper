# Icinga2 on StartOS — The Full Story

## What This Is

A monitoring dashboard that gives you a tactical overview of your entire network — 70 devices, 160+ services — running on your StartOS test box (haz1upstart003). Think of it as a second pair of eyes alongside Observium, but with a much better "war room" display.

Observium is great at discovering devices and collecting SNMP data, but its alerting dashboard is... functional at best. Icinga2's IcingaWeb2 interface gives you service groups, downtime scheduling, acknowledgment workflows, and the kind of at-a-glance status view that makes you feel like you're running a proper NOC.

## How It Works

The architecture is deliberately simple: **Observium stays the boss, Icinga2 is the display**.

```
Observium (haz1upmedia001)           Icinga2 (haz1upstart003)
┌──────────────────────┐             ┌──────────────────────┐
│ MySQL Database       │◄────────────│ sync-observium.py    │
│  ├─ devices table    │  reads      │  (every 6 hours)     │
│  └─ probes table     │             │                      │
│                      │             │ Generates:           │
│ 70 devices           │             │  ├─ hosts.conf       │
│ 163 probes           │             │  ├─ services.conf    │
│ Auto-synced from     │             │  └─ hostgroups.conf  │
│ NetBox daily         │             │                      │
└──────────────────────┘             │ Icinga2 daemon       │
                                     │  └─ Runs all checks  │
                                     │     independently    │
                                     │                      │
                                     │ IcingaWeb2 (port 80) │
                                     │  └─ Dashboard UI     │
                                     └──────────────────────┘
```

Every 6 hours (or on-demand via the StartOS UI), a Python script connects to Observium's MySQL, reads the device list and probe definitions, and generates Icinga2 configuration files. Icinga2 then runs those checks itself — pinging devices, checking SSH ports, querying SNMP, testing HTTP endpoints — all from its own location on the network.

This is important: Icinga2 doesn't just mirror Observium's results. It runs its own checks from haz1upstart003, which means you get a second vantage point. If Observium says a device is up but Icinga2 says it's down, you know there's a routing issue between the two monitoring boxes.

## The Container Stack

Inside the StartOS LXC container, four processes run under supervisord:

1. **MySQL 8.0** — Stores Icinga2's own state (check results, acknowledgments, downtimes)
2. **Icinga2** — The monitoring engine that executes all the checks
3. **Apache + PHP** — Serves the IcingaWeb2 web dashboard
4. **Cron** — Runs the Observium sync on schedule

This is the same pattern as the Observium wrapper — one container, multiple services, supervisord keeping everything alive.

## The LXC Permission Saga

This project taught us something important about StartOS 0.4.0's LXC containers that applies to every package with MySQL.

StartOS runs containers inside Linux namespaces. This means user IDs inside the container don't map to the same user IDs on the host. When MySQL (running as uid 100 inside the container) tries to write to its data directory, the kernel sees a completely different uid and says "Permission denied." Even though `ls -la` inside the container shows `mysql:mysql` ownership, the actual disk-level permissions don't match.

The fix is counterintuitive: run MySQL as root and make everything world-writable. Inside a container that has no external network access to MySQL (it's bound to 127.0.0.1), this is perfectly safe. But it took several rounds of debugging to figure out.

**The specific gotcha**: MySQL reads config files alphabetically. You can't just pass `--user=root` on the command line because the config file `/etc/mysql/mysql.conf.d/mysqld.cnf` sets `user = mysql` and MySQL ignores command-line user changes that conflict with config file settings. The fix is to create `lxc-compat.cnf` (which sorts after `mysqld.cnf`) with `user = root`.

Another fun discovery: `icinga2 api setup` generates TLS certificates using the container's hostname, not the Icinga2 `NodeName` constant. In LXC, the hostname is a random hash like `FBZ2AOMRN6EKKWIVLNWIHJL4HCMVPL3N`. So the cert gets generated for that hash, but Icinga2 looks for a cert matching `icinga2-startos`. You have to use `icinga2 pki new-cert --cn icinga2-startos` explicitly.

## The Build System Trap

Here's a subtle one that cost us a rebuild: the Makefile tracks specific "ingredients" for the s9pk package — `Dockerfile`, `javascript/index.js`, `icon.png`, `LICENSE`, and `assets/`. Notice what's NOT on that list: `docker_entrypoint.sh` and `scripts/sync-observium.py`.

This means if you edit the entrypoint script (which you will, frequently), `make` will say "nothing to do" because the s9pk is newer than all tracked ingredients. You have to `rm -f *.s9pk` to force a rebuild. We lost an hour debugging "why isn't my fix showing up" before realizing the old entrypoint was baked into the cached Docker image.

## Probe Translation

The sync script translates Observium probe types to Icinga2 CheckCommands:

| Observium Probe | Icinga2 CheckCommand | What It Checks |
|----------------|---------------------|----------------|
| `check_ssh` | `ssh` | SSH port responsive |
| `check_snmp` | `snmp-uptime` | SNMP agent alive, returns uptime |
| `check_curl` | `http` | HTTP/HTTPS endpoint responsive |
| `check_ping` | `ping4` | ICMP reachability |
| `check_dell_smart` | (skipped) | Custom plugin, not portable |

The script also auto-groups hosts by site prefix — `haz1` devices go in "Hazlet (Primary)", `olb1` in "Old Bridge", etc. — which gives you nice geographical grouping in the dashboard.

One schema surprise: Observium's probes table uses `probe_disabled` not `probe_deleted`. The column names in Observium's MySQL schema don't always match what you'd expect from the documentation. Always check the actual table structure.

## Technologies

- **Icinga2** (v2.15.2) — Monitoring engine, fork of Nagios with modern API and better config language
- **IcingaWeb2** — PHP dashboard for Icinga2
- **MySQL 8.0** — Icinga2 IDO (Icinga Data Output) and IcingaWeb2 session/user storage
- **StartOS SDK** (0.4.0-beta.58) — TypeScript SDK for package metadata, actions, health checks
- **supervisord** — Multi-process management inside the container
- **Python 3 + PyMySQL** — Observium sync bridge script
- **monitoring-plugins** — Standard Nagios/Icinga check plugins (check_ssh, check_http, check_snmp, etc.)

## Codebase Map

```
start9-icinga2_wrapper/
├── startos/                    # StartOS SDK integration
│   ├── manifest.ts             # Package metadata (id, title, volumes, images)
│   ├── main.ts                 # Daemon setup, health checks, password generation
│   ├── interfaces.ts           # Web UI port binding
│   ├── sdk.ts                  # 2-line SDK re-export
│   ├── index.ts                # Entry point
│   ├── utils.ts                # Port constants
│   ├── dependencies.ts         # Empty (standalone package)
│   ├── backups.ts              # Volume backup config
│   ├── fileModels/
│   │   └── config.yaml.ts      # Configuration schema (ts-matches validation)
│   ├── actions/
│   │   ├── index.ts            # Action registry
│   │   ├── configure-settings.ts  # Settings form (admin creds, DNS, Observium sync)
│   │   ├── view-credentials.ts    # Read-only credential display
│   │   └── sync-now.ts            # On-demand Observium sync trigger
│   └── install/
│       ├── versionGraph.ts     # Version migration graph
│       └── versions/
│           ├── index.ts
│           └── v1.0.0.ts       # Initial version migration
│
├── Dockerfile                  # Ubuntu 24.04 + Icinga2 repo + all packages
├── docker_entrypoint.sh        # 400-line init script (MySQL, Icinga2, IcingaWeb2, sync)
├── supervisord.conf            # 4 processes: mysql, icinga2, apache2, cron
├── scripts/
│   └── sync-observium.py       # Observium MySQL → Icinga2 config generator
├── assets/
│   ├── icinga2-apache.conf     # Apache vhost for IcingaWeb2
│   └── compat/
│       ├── backup.sh           # Volume backup hook
│       └── restore.sh          # Volume restore hook
├── icon.png                    # Package icon
├── LICENSE                     # GPL-2.0
├── Makefile                    # Build system
├── package.json                # Node dependencies
└── tsconfig.json               # TypeScript config
```

## Lessons Learned

1. **LXC user namespaces break everything that relies on file ownership.** Any service that runs as a non-root user and needs to write to a mounted volume will hit this. The universal fix: run as root, chmod 777. It feels wrong, but it's the right answer in a namespaced container.

2. **MySQL config file ordering matters.** Config files are read alphabetically within each directory. If you need to override a setting from `mysqld.cnf`, your file must sort AFTER it. Command-line flags don't reliably override config file settings.

3. **Icinga2's ITL is massive.** Before writing a custom CheckCommand, check `/usr/share/icinga2/include/` — there are 214 built-in commands. We accidentally defined a `snmp-uptime` command that conflicted with the ITL's built-in one.

4. **Icinga2 constants are truly constant.** Unlike most config languages where you can redefine a variable, Icinga2's `const` is enforced at parse time. If `constants.conf` defines `NodeName`, you cannot redefine it in `icinga2.conf`.

5. **Docker buildx has its own layer cache.** StartOS's `start-cli s9pk pack` uses buildx with a `docker-container` driver, which has a separate cache from regular `docker build`. Pruning Docker's build cache doesn't help — you need `docker buildx prune`.

6. **Always verify the actual database schema.** Observium's documentation and code don't always agree on column names. `probe_disabled` vs `probe_deleted` cost us a deployment cycle.

7. **The Makefile dependency list is incomplete by design.** Only "ingredients" listed by `start-cli s9pk list-ingredients` trigger rebuilds. Shell scripts, Python scripts, and config files that get COPY'd in the Dockerfile are NOT tracked. Delete the s9pk to force a full rebuild.

## What Good Engineering Looks Like Here

This project demonstrates a principle that experienced infrastructure engineers live by: **don't build what you can bridge**.

The temptation was to build Icinga2 as a standalone monitoring system — define all 70 devices manually, configure all 160 checks by hand, maintain two independent device inventories. That's how most tutorials teach it.

Instead, we kept Observium as the single source of truth and built a bridge. The sync script is 200 lines of Python. Adding a new device to Observium automatically adds it to Icinga2 on the next sync. No manual duplication, no configuration drift, no "I added it to Observium but forgot Icinga2."

This is the same principle behind infrastructure-as-code, GitOps, and every other pattern that says "one source of truth, everything else derives from it." The bridge might seem like extra complexity, but it's actually less complexity — because now you only have one place to maintain your device list.

The other engineering lesson: **accept the constraints of your platform**. LXC namespaces break file permissions? Don't fight it with elaborate chown chains — run as root and move on. The container is isolated, the MySQL socket is bound to localhost, there's no security benefit to running as the `mysql` user inside a namespace where user IDs are meaningless anyway. Pragmatic beats dogmatic.
