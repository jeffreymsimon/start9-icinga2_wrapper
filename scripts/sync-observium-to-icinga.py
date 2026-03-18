#!/usr/bin/env python3
"""
Observium → Icinga2 API Sync

Runs on haz1upmedia001 (where Observium lives). Reads the Observium MySQL
database locally, then pushes host and service objects to the Icinga2 API
running on haz1upstart003.

Host/service objects are created in Icinga2's config package "observium-sync"
so they can be managed independently of static config.

All synced services inherit the generic-service template:
  - check_interval = 300 (5 min)
  - retry_interval = 60 (1 min)
  - max_check_attempts = 3
This means: check every 5 min, on failure retry 3x at 1 min intervals,
then alert (via ntfy if configured).

Usage:
  python3 sync-observium-to-icinga.py --icinga-host 10.0.20.87 --icinga-pass <api-password>

Cron (every 15 min):
  */15 * * * * /usr/local/bin/sync-observium-to-icinga.py --icinga-host 10.0.20.87 --icinga-pass <pw> >> /var/log/observium/icinga-sync.log 2>&1
"""

import argparse
import json
import re
import sys
from collections import defaultdict
from datetime import datetime

try:
    import pymysql
except ImportError:
    print("ERROR: pymysql not installed. Run: pip3 install pymysql", file=sys.stderr)
    sys.exit(1)

try:
    import requests
    from requests.auth import HTTPBasicAuth
except ImportError:
    print("ERROR: requests not installed. Run: pip3 install requests", file=sys.stderr)
    sys.exit(1)


def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}")


def connect_observium(host="localhost", user="observium", password="", database="observium"):
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
    cursor.execute("""
        SELECT device_id, hostname, sysName, ip, os, type, location
        FROM devices
        WHERE disabled = 0 AND status = 1
        ORDER BY hostname
    """)
    return cursor.fetchall()


def fetch_probes(cursor):
    cursor.execute("""
        SELECT probe_id, device_id, probe_descr, probe_type, probe_args
        FROM probes
        WHERE probe_disabled = 0
        ORDER BY device_id, probe_type
    """)
    return cursor.fetchall()


def sanitize_name(name):
    """Convert hostname/description to Icinga2-safe object name."""
    safe = re.sub(r"[^a-zA-Z0-9._-]", "_", name)
    return safe.strip("_")


def site_prefix(hostname):
    match = re.match(r"^([a-z]+\d+)", hostname)
    return match.group(1) if match else "unknown"


def parse_curl_args(probe_args):
    extra = {}
    host_match = re.search(r"-H\s+(\S+)", probe_args)
    if host_match:
        extra["check_curl_hostname"] = host_match.group(1)
    port_match = re.search(r"-p\s+(\d+)", probe_args)
    if port_match:
        extra["check_curl_port"] = port_match.group(1)
    if "-S" in probe_args or "--sni" in probe_args:
        extra["check_curl_ssl"] = True
    if "-k" in probe_args:
        extra["check_curl_insecure"] = True
    return extra


def parse_snmp_args(probe_args, snmp_community):
    extra = {"snmp_community": snmp_community}
    oid_match = re.search(r"-o\s+([.\d]+)", probe_args)
    if oid_match:
        extra["snmp_oid"] = oid_match.group(1)
    warn_match = re.search(r"-w\s+(\S+)", probe_args)
    if warn_match:
        extra["snmp_warn"] = warn_match.group(1)
    crit_match = re.search(r"-c\s+(\S+)", probe_args)
    if crit_match:
        extra["snmp_crit"] = crit_match.group(1)
    label_match = re.search(r'-l\s+"([^"]+)"', probe_args)
    if label_match:
        extra["snmp_label"] = label_match.group(1)
    return extra


def parse_cloudflare_tunnel_args(probe_args):
    extra = {}
    tunnel_match = re.search(r"-T\s+([\w-]+)", probe_args)
    if tunnel_match:
        extra["cf_tunnel_id"] = tunnel_match.group(1)
    extra["cf_config_file"] = "/etc/icinga2/cloudflare.conf"
    return extra


class IcingaAPI:
    def __init__(self, host, port=5665, user="root", password=""):
        self.base_url = f"https://{host}:{port}/v1"
        self.auth = HTTPBasicAuth(user, password)
        self.session = requests.Session()
        self.session.verify = False  # Self-signed cert
        self.session.auth = self.auth
        self.session.headers.update({"Accept": "application/json"})

    def get_existing_hosts(self):
        """Get all hosts currently in Icinga2."""
        r = self.session.get(f"{self.base_url}/objects/hosts")
        if r.status_code != 200:
            log(f"WARNING: Failed to fetch hosts: {r.status_code}")
            return {}
        data = r.json()
        return {obj["name"]: obj for obj in data.get("results", [])}

    def get_existing_services(self):
        """Get all services currently in Icinga2."""
        r = self.session.get(f"{self.base_url}/objects/services")
        if r.status_code != 200:
            log(f"WARNING: Failed to fetch services: {r.status_code}")
            return {}
        data = r.json()
        return {obj["name"]: obj for obj in data.get("results", [])}

    def put_host(self, name, attrs, templates=None):
        """Create or update a host via config package API."""
        payload = {"attrs": attrs}
        if templates:
            payload["templates"] = templates
        r = self.session.put(
            f"{self.base_url}/objects/hosts/{name}",
            json=payload,
            headers={"Content-Type": "application/json"},
        )
        return r.status_code in (200, 201)

    def put_service(self, host_name, service_name, attrs, templates=None):
        """Create or update a service via config package API."""
        payload = {"attrs": attrs}
        if templates:
            payload["templates"] = templates
        r = self.session.put(
            f"{self.base_url}/objects/services/{host_name}!{service_name}",
            json=payload,
            headers={"Content-Type": "application/json"},
        )
        return r.status_code in (200, 201)

    def delete_host(self, name):
        r = self.session.delete(
            f"{self.base_url}/objects/hosts/{name}",
            json={"cascade": True},
            headers={"Content-Type": "application/json"},
        )
        return r.status_code == 200

    def delete_service(self, host_name, service_name):
        r = self.session.delete(
            f"{self.base_url}/objects/services/{host_name}!{service_name}",
            headers={"Content-Type": "application/json"},
        )
        return r.status_code == 200

    def test_connection(self):
        """Test API connectivity."""
        try:
            r = self.session.get(f"{self.base_url}/status")
            return r.status_code == 200
        except requests.ConnectionError:
            return False


def map_probe_to_service(probe, snmp_community):
    """Map an Observium probe to Icinga2 service attributes."""
    probe_type = probe["probe_type"]
    probe_descr = probe["probe_descr"] or probe_type
    probe_args = probe.get("probe_args") or ""

    if probe_type == "check_ssh":
        return "ssh", "ssh", {}

    elif probe_type == "check_snmp":
        extra = parse_snmp_args(probe_args, snmp_community)
        oid = extra.get("snmp_oid", "")
        if oid == ".1.3.6.1.2.1.1.3.0":
            return "snmp-uptime", "snmp-uptime", extra
        elif "snmp_warn" in extra or "snmp_crit" in extra:
            return sanitize_name(probe_descr) or "snmp", "snmp", extra
        else:
            return sanitize_name(probe_descr) or "snmp", "snmp-uptime", extra

    elif probe_type in ("check_curl", "check_http"):
        extra = parse_curl_args(probe_args)
        return sanitize_name(probe_descr) or "http", "check_curl", extra

    elif probe_type == "check_ping":
        return "ping", "ping4", {}

    elif probe_type == "check_cloudflare_tunnel":
        extra = parse_cloudflare_tunnel_args(probe_args)
        return sanitize_name(probe_descr) or "cloudflare-tunnel", "check_cloudflare_tunnel", extra

    elif probe_type == "check_dell_smart":
        return sanitize_name(probe_descr) or "dell-smart", "check_dell_smart", {"dell_smart_community": snmp_community}

    return None, None, None


def main():
    parser = argparse.ArgumentParser(description="Sync Observium → Icinga2 via API")
    parser.add_argument("--db-host", default="localhost", help="Observium MySQL host")
    parser.add_argument("--db-user", default="observium", help="Observium MySQL user")
    parser.add_argument("--db-pass", default="deZ6YivYR5m8CyK", help="Observium MySQL password")
    parser.add_argument("--snmp-community", default="10fir")
    parser.add_argument("--icinga-host", required=True, help="Icinga2 API host (e.g. 10.0.20.87)")
    parser.add_argument("--icinga-port", type=int, default=5665)
    parser.add_argument("--icinga-user", default="root")
    parser.add_argument("--icinga-pass", required=True, help="Icinga2 API password")
    parser.add_argument("--check-interval", type=int, default=300, help="Check interval in seconds (default: 300 = 5min)")
    parser.add_argument("--retry-interval", type=int, default=60, help="Retry interval in seconds (default: 60)")
    parser.add_argument("--max-attempts", type=int, default=3, help="Max check attempts before hard state (default: 3)")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be done without making changes")
    parser.add_argument("--cleanup", action="store_true", help="Remove Icinga2 hosts/services not in Observium")
    args = parser.parse_args()

    # Suppress InsecureRequestWarning for self-signed cert
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    # Connect to Observium DB
    log("Connecting to Observium database...")
    try:
        conn = connect_observium(args.db_host, args.db_user, args.db_pass)
    except Exception as e:
        log(f"ERROR: Cannot connect to Observium DB: {e}")
        sys.exit(1)

    try:
        with conn.cursor() as cursor:
            devices = fetch_devices(cursor)
            probes = fetch_probes(cursor)
    finally:
        conn.close()

    log(f"Fetched {len(devices)} devices, {len(probes)} probes from Observium")

    if not devices:
        log("WARNING: No devices found in Observium")
        return

    # Connect to Icinga2 API
    icinga = IcingaAPI(args.icinga_host, args.icinga_port, args.icinga_user, args.icinga_pass)

    if not args.dry_run:
        log(f"Testing Icinga2 API connection at {args.icinga_host}:{args.icinga_port}...")
        if not icinga.test_connection():
            log("ERROR: Cannot connect to Icinga2 API")
            sys.exit(1)
        log("Icinga2 API connection OK")

    # Get existing objects for comparison
    existing_hosts = {}
    existing_services = {}
    if not args.dry_run:
        existing_hosts = icinga.get_existing_hosts()
        existing_services = icinga.get_existing_services()

    # Build device map
    dev_map = {d["device_id"]: d for d in devices}

    # Sync hosts
    hosts_created = 0
    hosts_updated = 0
    observium_host_names = set()

    for dev in devices:
        hostname = dev["hostname"]
        safe_name = sanitize_name(hostname)
        observium_host_names.add(safe_name)
        address = dev["ip"] or hostname
        location = (dev.get("location") or "").replace('"', '\\"')
        os_type = dev.get("os") or "unknown"
        dev_type = dev.get("type") or "unknown"

        attrs = {
            "address": address,
            "check_command": "hostalive",
            "check_interval": args.check_interval,
            "retry_interval": args.retry_interval,
            "max_check_attempts": args.max_attempts,
            "vars.location": location,
            "vars.os": os_type,
            "vars.device_type": dev_type,
            "vars.observium_id": dev["device_id"],
            "vars.site": site_prefix(hostname),
            "vars.managed_by": "observium-sync",
        }

        if args.dry_run:
            action = "UPDATE" if safe_name in existing_hosts else "CREATE"
            log(f"  [DRY-RUN] {action} host: {safe_name} ({address})")
        else:
            ok = icinga.put_host(safe_name, attrs, templates=["generic-host"])
            if ok:
                if safe_name in existing_hosts:
                    hosts_updated += 1
                else:
                    hosts_created += 1
            else:
                log(f"  WARNING: Failed to sync host {safe_name}")

    # Sync services
    probes_by_device = defaultdict(list)
    for p in probes:
        if p["device_id"] in dev_map:
            probes_by_device[p["device_id"]].append(p)

    svcs_created = 0
    svcs_updated = 0
    observium_svc_names = set()

    for device_id, device_probes in sorted(probes_by_device.items()):
        dev = dev_map[device_id]
        host_name = sanitize_name(dev["hostname"])
        seen_names = set()

        for probe in device_probes:
            svc_name, check_cmd, extra_vars = map_probe_to_service(probe, args.snmp_community)
            if svc_name is None:
                continue

            # Deduplicate
            base_name = svc_name
            counter = 1
            while svc_name in seen_names:
                counter += 1
                svc_name = f"{base_name}-{counter}"
            seen_names.add(svc_name)

            full_name = f"{host_name}!{svc_name}"
            observium_svc_names.add(full_name)

            attrs = {
                "check_command": check_cmd,
                "check_interval": args.check_interval,
                "retry_interval": args.retry_interval,
                "max_check_attempts": args.max_attempts,
                "vars.observium_probe_id": probe["probe_id"],
                "vars.managed_by": "observium-sync",
            }
            for k, v in extra_vars.items():
                attrs[f"vars.{k}"] = v

            if args.dry_run:
                action = "UPDATE" if full_name in existing_services else "CREATE"
                log(f"  [DRY-RUN] {action} service: {full_name} ({check_cmd})")
            else:
                ok = icinga.put_service(host_name, svc_name, attrs, templates=["generic-service"])
                if ok:
                    if full_name in existing_services:
                        svcs_updated += 1
                    else:
                        svcs_created += 1
                else:
                    log(f"  WARNING: Failed to sync service {full_name}")

    # Cleanup: remove hosts/services not in Observium (only managed ones)
    hosts_removed = 0
    svcs_removed = 0
    if args.cleanup and not args.dry_run:
        for name, obj in existing_hosts.items():
            attrs = obj.get("attrs", {})
            if attrs.get("vars", {}).get("managed_by") == "observium-sync":
                if name not in observium_host_names:
                    log(f"  Removing stale host: {name}")
                    icinga.delete_host(name)
                    hosts_removed += 1

        for name, obj in existing_services.items():
            attrs = obj.get("attrs", {})
            if attrs.get("vars", {}).get("managed_by") == "observium-sync":
                if name not in observium_svc_names:
                    log(f"  Removing stale service: {name}")
                    parts = name.split("!", 1)
                    if len(parts) == 2:
                        icinga.delete_service(parts[0], parts[1])
                        svcs_removed += 1

    log(f"Sync complete: hosts({hosts_created} created, {hosts_updated} updated, {hosts_removed} removed) "
        f"services({svcs_created} created, {svcs_updated} updated, {svcs_removed} removed)")


if __name__ == "__main__":
    main()
