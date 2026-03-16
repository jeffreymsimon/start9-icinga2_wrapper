#!/usr/bin/env python3
"""
Observium → Icinga2 Sync Bridge

Connects to Observium's MySQL database, reads device and probe definitions,
and generates equivalent Icinga2 host/service configuration files.

Probe type mapping:
  check_ssh   → Icinga2 ssh CheckCommand
  check_snmp  → Icinga2 snmp-uptime (custom) or snmp CheckCommand
  check_curl  → Icinga2 http CheckCommand
  check_ping  → Icinga2 ping4 CheckCommand
"""

import argparse
import os
import re
import sys
from collections import defaultdict

try:
    import pymysql
except ImportError:
    print("ERROR: pymysql not installed", file=sys.stderr)
    sys.exit(1)


def connect_db(host, user, password, database="observium"):
    return pymysql.connect(
        host=host,
        user=user,
        password=password,
        database=database,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=10,
        read_timeout=30,
    )


def fetch_devices(cursor):
    cursor.execute(
        """
        SELECT device_id, hostname, sysName, ip, os, type, location
        FROM devices
        WHERE disabled = 0 AND status = 1
        ORDER BY hostname
        """
    )
    return cursor.fetchall()


def fetch_probes(cursor):
    cursor.execute(
        """
        SELECT probe_id, device_id, probe_descr, probe_type, probe_args
        FROM probes
        WHERE probe_deleted = 0
        ORDER BY device_id, probe_type
        """
    )
    return cursor.fetchall()


def sanitize_name(name):
    """Convert hostname/description to Icinga2-safe object name."""
    safe = re.sub(r"[^a-zA-Z0-9._-]", "_", name)
    return safe.strip("_")


def site_prefix(hostname):
    """Extract site prefix from hostname (e.g., haz1, olb1, wtn1)."""
    match = re.match(r"^([a-z]+\d+)", hostname)
    return match.group(1) if match else "unknown"


def generate_hosts_conf(devices, check_interval, retry_interval, max_attempts):
    lines = [
        "/* Auto-generated from Observium - do not edit manually */",
        "",
    ]
    for dev in devices:
        hostname = dev["hostname"]
        address = dev["ip"] or hostname
        safe_name = sanitize_name(hostname)
        location = (dev.get("location") or "").replace('"', '\\"')
        os_type = dev.get("os") or "unknown"
        dev_type = dev.get("type") or "unknown"

        lines.append(f'object Host "{safe_name}" {{')
        lines.append('  import "generic-host"')
        lines.append(f'  address = "{address}"')
        lines.append(f'  vars.location = "{location}"')
        lines.append(f'  vars.os = "{os_type}"')
        lines.append(f'  vars.device_type = "{dev_type}"')
        lines.append(f'  vars.observium_id = {dev["device_id"]}')
        lines.append(f'  vars.site = "{site_prefix(hostname)}"')
        lines.append("}")
        lines.append("")

    return "\n".join(lines)


def generate_services_conf(devices, probes, snmp_community):
    # Build device_id -> hostname map
    dev_map = {d["device_id"]: sanitize_name(d["hostname"]) for d in devices}

    # Group probes by device
    probes_by_device = defaultdict(list)
    for p in probes:
        if p["device_id"] in dev_map:
            probes_by_device[p["device_id"]].append(p)

    lines = [
        "/* Auto-generated services from Observium probes */",
        "",
    ]

    for device_id, device_probes in sorted(probes_by_device.items()):
        host_name = dev_map[device_id]

        # Track service names to avoid duplicates
        seen_names = set()

        for probe in device_probes:
            probe_type = probe["probe_type"]
            probe_descr = probe["probe_descr"] or probe_type
            probe_args = probe.get("probe_args") or ""

            # Determine Icinga2 check command and arguments
            check_cmd = None
            extra_vars = {}

            if probe_type == "check_ssh":
                svc_name = "ssh"
                check_cmd = "ssh"

            elif probe_type == "check_snmp":
                svc_name = sanitize_name(probe_descr) or "snmp"
                # Parse OID from args if present
                oid_match = re.search(r"-o\s+([.\d]+)", probe_args)
                if oid_match and oid_match.group(1) == ".1.3.6.1.2.1.1.3.0":
                    check_cmd = "snmp-uptime"
                    svc_name = "snmp-uptime"
                else:
                    check_cmd = "snmp-uptime"
                    svc_name = "snmp"
                extra_vars["snmp_community"] = snmp_community

            elif probe_type in ("check_curl", "check_http"):
                svc_name = sanitize_name(probe_descr) or "http"
                check_cmd = "http"
                # Check if HTTPS
                if "443" in probe_args or "-S" in probe_args or "https" in probe_args.lower():
                    extra_vars["http_ssl"] = "true"
                    extra_vars["http_sni"] = "true"
                    if "-k" in probe_args:
                        extra_vars["http_ssl_force_tlsv1_2_or_higher"] = "false"
                    svc_name = "https" if svc_name in ("http", "check_curl") else svc_name

            elif probe_type == "check_ping":
                svc_name = "ping"
                check_cmd = "ping4"

            elif probe_type == "check_dell_smart":
                # Custom probe - skip for now (requires custom plugin)
                continue

            else:
                # Unknown probe type - skip
                continue

            # Deduplicate service names per host
            base_name = svc_name
            counter = 1
            while svc_name in seen_names:
                counter += 1
                svc_name = f"{base_name}-{counter}"
            seen_names.add(svc_name)

            lines.append(f'object Service "{svc_name}" {{')
            lines.append('  import "generic-service"')
            lines.append(f'  host_name = "{host_name}"')
            lines.append(f'  check_command = "{check_cmd}"')
            lines.append(f'  vars.observium_probe_id = {probe["probe_id"]}')
            for k, v in extra_vars.items():
                if v == "true" or v == "false":
                    lines.append(f"  vars.{k} = {v}")
                else:
                    lines.append(f'  vars.{k} = "{v}"')
            lines.append("}")
            lines.append("")

    return "\n".join(lines)


def generate_hostgroups_conf(devices):
    # Group by site prefix
    sites = defaultdict(list)
    for dev in devices:
        prefix = site_prefix(dev["hostname"])
        sites[prefix].append(sanitize_name(dev["hostname"]))

    lines = [
        "/* Auto-generated host groups by site */",
        "",
    ]

    site_names = {
        "haz1": "Hazlet (Primary)",
        "haz5": "Hazlet 5",
        "olb1": "Old Bridge",
        "wtn1": "Waretown",
        "tmr2": "Toms River 2",
        "win1": "Winhall",
        "bel1": "Belford",
        "rbk1": "Red Bank",
    }

    for prefix in sorted(sites.keys()):
        display_name = site_names.get(prefix, prefix.upper())
        lines.append(f'object HostGroup "{prefix}" {{')
        lines.append(f'  display_name = "{display_name}"')
        lines.append(f'  assign where host.vars.site == "{prefix}"')
        lines.append("}")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Sync Observium to Icinga2")
    parser.add_argument("--db-host", required=True)
    parser.add_argument("--db-user", required=True)
    parser.add_argument("--db-pass", required=True)
    parser.add_argument("--snmp-community", default="10fir")
    parser.add_argument("--check-interval", type=int, default=300)
    parser.add_argument("--retry-interval", type=int, default=60)
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--output-dir", default="/etc/icinga2/conf.d/generated/")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    try:
        conn = connect_db(args.db_host, args.db_user, args.db_pass)
    except Exception as e:
        print(f"ERROR: Cannot connect to Observium DB: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        with conn.cursor() as cursor:
            devices = fetch_devices(cursor)
            probes = fetch_probes(cursor)
    finally:
        conn.close()

    print(f"Fetched {len(devices)} devices, {len(probes)} probes from Observium")

    if not devices:
        print("WARNING: No devices found in Observium")
        return

    # Generate configs
    hosts = generate_hosts_conf(
        devices, args.check_interval, args.retry_interval, args.max_attempts
    )
    services = generate_services_conf(devices, probes, args.snmp_community)
    hostgroups = generate_hostgroups_conf(devices)

    # Write files
    with open(os.path.join(args.output_dir, "hosts.conf"), "w") as f:
        f.write(hosts)
    with open(os.path.join(args.output_dir, "services.conf"), "w") as f:
        f.write(services)
    with open(os.path.join(args.output_dir, "hostgroups.conf"), "w") as f:
        f.write(hostgroups)

    # Count services
    svc_count = services.count('object Service "')
    print(f"Generated: {len(devices)} hosts, {svc_count} services, {len(set(site_prefix(d['hostname']) for d in devices))} host groups")
    print(f"Written to: {args.output_dir}")


if __name__ == "__main__":
    main()
