#!/bin/bash
set -e

echo "============================================"
echo "  Icinga2 StartOS Package - Entrypoint"
echo "============================================"

# ==================== Configuration Helpers ====================

CONFIG_FILE="/root/data/start9/config.yaml"

get_config() {
    local key="$1"
    local default="$2"
    if [ -f "$CONFIG_FILE" ]; then
        local val
        val=$(yq -r ".[\"$key\"] // \"\"" "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" != "null" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# Wait for config file from StartOS
echo "Waiting for configuration..."
WAIT_COUNT=0
while [ ! -f "$CONFIG_FILE" ]; do
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ $WAIT_COUNT -ge 60 ]; then
        echo "WARNING: Config file not found after 60s, using defaults"
        break
    fi
done

# ==================== Load Configuration ====================

ADMIN_USER="${S9_ICINGA2_ADMIN_USERNAME:-admin}"
ADMIN_PASS="${S9_ICINGA2_ADMIN_PASSWORD:-}"
DB_PASS="${S9_ICINGA2_DB_PASSWORD:-}"
API_PASS="${S9_ICINGA2_API_PASSWORD:-}"
DNS_PRIMARY="${S9_ICINGA2_PRIMARY_DNS:-10.0.20.1}"
DNS_SECONDARY="${S9_ICINGA2_SECONDARY_DNS:-1.1.1.1}"
CHECK_INTERVAL="${S9_ICINGA2_CHECK_INTERVAL:-300}"
RETRY_INTERVAL="${S9_ICINGA2_RETRY_INTERVAL:-60}"
MAX_CHECK_ATTEMPTS="${S9_ICINGA2_MAX_CHECK_ATTEMPTS:-3}"
SNMP_COMMUNITY="${S9_ICINGA2_SNMP_COMMUNITY:-10fir}"
OBSERVIUM_SYNC="${S9_ICINGA2_OBSERVIUM_SYNC:-false}"
OBSERVIUM_DB_HOST="${S9_ICINGA2_OBSERVIUM_DB_HOST:-10.0.60.125}"
OBSERVIUM_DB_USER="${S9_ICINGA2_OBSERVIUM_DB_USER:-observium}"
OBSERVIUM_DB_PASS="${S9_ICINGA2_OBSERVIUM_DB_PASSWORD:-}"
LOG_LEVEL="${S9_ICINGA2_LOG_LEVEL:-warning}"

echo "Configuration loaded:"
echo "  Admin: $ADMIN_USER"
echo "  DNS: $DNS_PRIMARY / $DNS_SECONDARY"
echo "  Check Interval: ${CHECK_INTERVAL}s"
echo "  SNMP Community: $SNMP_COMMUNITY"
echo "  Observium Sync: $OBSERVIUM_SYNC"
echo "  Log Level: $LOG_LEVEL"

# ==================== DNS Configuration ====================

echo "Configuring DNS..."
cat > /etc/resolv.conf << EOF
nameserver $DNS_PRIMARY
nameserver $DNS_SECONDARY
options timeout:2 attempts:2
EOF

# ==================== MySQL Initialization ====================

MYSQL_DATA="/root/data/mysql"
DB_INIT_FLAG="/root/data/.db_initialized"

echo "Initializing MySQL..."

# Ensure MySQL directories exist with correct ownership
mkdir -p "$MYSQL_DATA" /var/run/mysqld /var/log/mysql
chown -R mysql:mysql "$MYSQL_DATA" /var/run/mysqld /var/log/mysql

# MySQL config for LXC compatibility
cat > /etc/mysql/mysql.conf.d/lxc-compat.cnf << 'EOF'
[mysqld]
datadir = /root/data/mysql
socket = /var/run/mysqld/mysqld.sock
innodb_use_native_aio = 0
innodb_flush_method = O_DSYNC
skip-grant-tables = 0
bind-address = 127.0.0.1
EOF

# Initialize MySQL data directory if empty
if [ ! -d "$MYSQL_DATA/mysql" ]; then
    echo "Initializing MySQL data directory..."
    mysqld --initialize-insecure --user=mysql --datadir="$MYSQL_DATA"
fi

# Start MySQL temporarily for setup
echo "Starting MySQL for initial setup..."
mysqld_safe &
MYSQL_PID=$!

# Wait for MySQL to be ready
for i in $(seq 1 30); do
    if mysqladmin ping --socket=/var/run/mysqld/mysqld.sock 2>/dev/null; then
        echo "MySQL is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "ERROR: MySQL failed to start"
        exit 1
    fi
    sleep 1
done

# ==================== Database Setup ====================

if [ ! -f "$DB_INIT_FLAG" ]; then
    echo "Creating Icinga2 databases..."

    # Set root password
    mysql --socket=/var/run/mysqld/mysqld.sock -u root << EOSQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
EOSQL

    # Create IDO database
    mysql --socket=/var/run/mysqld/mysqld.sock -u root -p"${DB_PASS}" << EOSQL
CREATE DATABASE IF NOT EXISTS icinga2_ido CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'icinga2'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL ON icinga2_ido.* TO 'icinga2'@'localhost';
FLUSH PRIVILEGES;
EOSQL

    # Import IDO schema
    echo "Importing Icinga2 IDO schema..."
    mysql --socket=/var/run/mysqld/mysqld.sock -u root -p"${DB_PASS}" icinga2_ido < /usr/share/icinga2-ido-mysql/schema/mysql.sql

    # Create IcingaWeb2 database
    mysql --socket=/var/run/mysqld/mysqld.sock -u root -p"${DB_PASS}" << EOSQL
CREATE DATABASE IF NOT EXISTS icingaweb2 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'icingaweb2'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL ON icingaweb2.* TO 'icingaweb2'@'localhost';
FLUSH PRIVILEGES;
EOSQL

    # Import IcingaWeb2 schema
    echo "Importing IcingaWeb2 schema..."
    mysql --socket=/var/run/mysqld/mysqld.sock -u root -p"${DB_PASS}" icingaweb2 < /usr/share/icingaweb2/schema/mysql.sql

    touch "$DB_INIT_FLAG"
    echo "Database initialization complete"
fi

# ==================== Admin User Setup ====================

echo "Setting up admin user..."

# Generate bcrypt hash for admin password using PHP
ADMIN_HASH=$(php -r "echo password_hash('${ADMIN_PASS}', PASSWORD_BCRYPT);")

# Insert or update admin user
mysql --socket=/var/run/mysqld/mysqld.sock -u root -p"${DB_PASS}" icingaweb2 << EOSQL
INSERT INTO icingaweb_user (name, active, password_hash)
VALUES ('${ADMIN_USER}', 1, '${ADMIN_HASH}')
ON DUPLICATE KEY UPDATE password_hash='${ADMIN_HASH}', active=1;
EOSQL

# ==================== Icinga2 Configuration ====================

echo "Configuring Icinga2..."

# Enable IDO MySQL feature
mkdir -p /etc/icinga2/features-enabled

cat > /etc/icinga2/features-available/ido-mysql.conf << EOF
library "db_ido_mysql"

object IdoMysqlConnection "ido-mysql" {
  user = "icinga2"
  password = "${DB_PASS}"
  host = "localhost"
  database = "icinga2_ido"
  socket_path = "/var/run/mysqld/mysqld.sock"
}
EOF

# Enable API feature
cat > /etc/icinga2/features-available/api.conf << EOF
object ApiListener "api" {
  cert_path = SysconfDir + "/icinga2/pki/" + NodeName + ".crt"
  key_path = SysconfDir + "/icinga2/pki/" + NodeName + ".key"
  ca_path = SysconfDir + "/icinga2/pki/ca.crt"

  accept_config = true
  accept_commands = true

  bind_host = "127.0.0.1"
  bind_port = 5665
}

object ApiUser "root" {
  password = "${API_PASS}"
  permissions = [ "*" ]
}
EOF

# Symlink enabled features
ln -sf /etc/icinga2/features-available/ido-mysql.conf /etc/icinga2/features-enabled/
ln -sf /etc/icinga2/features-available/api.conf /etc/icinga2/features-enabled/
ln -sf /etc/icinga2/features-available/checker.conf /etc/icinga2/features-enabled/ 2>/dev/null || true
ln -sf /etc/icinga2/features-available/mainlog.conf /etc/icinga2/features-enabled/ 2>/dev/null || true
ln -sf /etc/icinga2/features-available/notification.conf /etc/icinga2/features-enabled/ 2>/dev/null || true

# Set up Icinga2 API PKI (generate self-signed certs if missing)
ICINGA2_NODE="icinga2-startos"
if [ ! -f /etc/icinga2/pki/${ICINGA2_NODE}.crt ]; then
    echo "Generating Icinga2 API certificates..."
    mkdir -p /etc/icinga2/pki
    icinga2 pki new-ca
    icinga2 pki new-cert --cn ${ICINGA2_NODE} \
        --key /etc/icinga2/pki/${ICINGA2_NODE}.key \
        --csr /etc/icinga2/pki/${ICINGA2_NODE}.csr
    icinga2 pki sign-csr --csr /etc/icinga2/pki/${ICINGA2_NODE}.csr \
        --cert /etc/icinga2/pki/${ICINGA2_NODE}.crt
    cp /var/lib/icinga2/ca/ca.crt /etc/icinga2/pki/ca.crt
    chown -R nagios:nagios /etc/icinga2/pki
fi

# Write main icinga2.conf
cat > /etc/icinga2/icinga2.conf << EOF
/**
 * Icinga2 configuration - generated by StartOS entrypoint
 */

include "constants.conf"

const NodeName = "${ICINGA2_NODE}"
const ZoneName = "master"

object Endpoint NodeName {
  host = "127.0.0.1"
}

object Zone ZoneName {
  endpoints = [ NodeName ]
}

include "zones.conf"
include <itl>
include <plugins>
include <plugins-contrib>
include "features-enabled/*.conf"
include_recursive "conf.d"
EOF

# Set log level in constants
cat > /etc/icinga2/constants.conf << EOF
const PluginDir = "/usr/lib/nagios/plugins"
const PluginContribDir = "/usr/lib/nagios/plugins"
const ManubulonPluginDir = "/usr/lib/nagios/plugins"
const NodeName = "${ICINGA2_NODE}"
const ZoneName = "master"
const TicketSalt = ""
EOF

# Write zones.conf (empty for single-node)
cat > /etc/icinga2/zones.conf << 'EOF'
/* Zones configuration - single node setup */
EOF

# Write default templates
cat > /etc/icinga2/conf.d/templates.conf << EOF
template Host "generic-host" {
  max_check_attempts = ${MAX_CHECK_ATTEMPTS}
  check_interval = ${CHECK_INTERVAL}
  retry_interval = ${RETRY_INTERVAL}
  check_command = "hostalive"
}

template Service "generic-service" {
  max_check_attempts = ${MAX_CHECK_ATTEMPTS}
  check_interval = ${CHECK_INTERVAL}
  retry_interval = ${RETRY_INTERVAL}
}
EOF

# Write default commands (custom check_snmp with community)
cat > /etc/icinga2/conf.d/commands.conf << EOF
/* Custom check commands */
object CheckCommand "snmp-uptime" {
  command = [ PluginDir + "/check_snmp" ]
  arguments = {
    "-H" = "\$address\$"
    "-C" = "\$snmp_community\$"
    "-o" = ".1.3.6.1.2.1.1.3.0"
  }
  vars.snmp_community = "${SNMP_COMMUNITY}"
}
EOF

# Write localhost monitoring
cat > /etc/icinga2/conf.d/hosts.conf << EOF
object Host "localhost" {
  import "generic-host"
  address = "127.0.0.1"
  vars.os = "Linux"
}
EOF

cat > /etc/icinga2/conf.d/services.conf << EOF
apply Service "ping" {
  import "generic-service"
  check_command = "ping4"
  assign where host.address
}

apply Service "load" {
  import "generic-service"
  check_command = "load"
  assign where host.name == "localhost"
}

apply Service "procs" {
  import "generic-service"
  check_command = "procs"
  assign where host.name == "localhost"
}

apply Service "disk" {
  import "generic-service"
  check_command = "disk"
  assign where host.name == "localhost"
}
EOF

# Ensure generated directory exists (for Observium sync)
mkdir -p /etc/icinga2/conf.d/generated
touch /etc/icinga2/conf.d/generated/.keep

# Fix Icinga2 permissions
chown -R nagios:nagios /var/run/icinga2 /var/log/icinga2 /var/lib/icinga2
chown -R nagios:nagios /etc/icinga2/conf.d/generated

# ==================== IcingaWeb2 Configuration ====================

echo "Configuring IcingaWeb2..."

ICINGAWEB_CONF="/etc/icingaweb2"

# config.ini
cat > "$ICINGAWEB_CONF/config.ini" << EOF
[logging]
log = "syslog"
level = "WARNING"

[global]
show_stacktraces = "1"
config_backend = "db"
config_resource = "icingaweb2_db"
EOF

# resources.ini
cat > "$ICINGAWEB_CONF/resources.ini" << EOF
[icingaweb2_db]
type = "db"
db = "mysql"
host = "localhost"
port = ""
dbname = "icingaweb2"
username = "icingaweb2"
password = "${DB_PASS}"
charset = "utf8mb4"
use_ssl = "0"

[icinga2_ido]
type = "db"
db = "mysql"
host = "localhost"
port = ""
dbname = "icinga2_ido"
username = "icinga2"
password = "${DB_PASS}"
charset = "utf8mb4"
use_ssl = "0"
EOF

# authentication.ini
cat > "$ICINGAWEB_CONF/authentication.ini" << EOF
[icingaweb2]
backend = "db"
resource = "icingaweb2_db"
EOF

# roles.ini
cat > "$ICINGAWEB_CONF/roles.ini" << EOF
[Administrators]
users = "${ADMIN_USER}"
permissions = "*"
EOF

# groups.ini
cat > "$ICINGAWEB_CONF/groups.ini" << EOF
[icingaweb2]
backend = "db"
resource = "icingaweb2_db"
EOF

# Enable monitoring module
mkdir -p "$ICINGAWEB_CONF/enabledModules"
ln -sf /usr/share/icingaweb2/modules/monitoring "$ICINGAWEB_CONF/enabledModules/monitoring"

# Monitoring module config
mkdir -p "$ICINGAWEB_CONF/modules/monitoring"

cat > "$ICINGAWEB_CONF/modules/monitoring/config.ini" << 'EOF'
[security]
protected_customvars = "*pw*,*pass*,community"
EOF

cat > "$ICINGAWEB_CONF/modules/monitoring/backends.ini" << EOF
[icinga2]
type = "ido"
resource = "icinga2_ido"
EOF

cat > "$ICINGAWEB_CONF/modules/monitoring/commandtransports.ini" << EOF
[icinga2]
transport = "api"
host = "127.0.0.1"
port = "5665"
username = "root"
password = "${API_PASS}"
EOF

# Fix IcingaWeb2 permissions
chown -R www-data:icingaweb2 "$ICINGAWEB_CONF"
chmod 2770 "$ICINGAWEB_CONF"
find "$ICINGAWEB_CONF" -type f -exec chmod 660 {} \;
find "$ICINGAWEB_CONF" -type d -exec chmod 2770 {} \;

# Ensure PHP session directory exists
mkdir -p /var/lib/php/sessions
chown www-data:www-data /var/lib/php/sessions

# ==================== Observium Sync ====================

if [ "$OBSERVIUM_SYNC" = "true" ]; then
    echo "Running initial Observium sync..."
    python3 /usr/local/bin/sync-observium.py \
        --db-host "$OBSERVIUM_DB_HOST" \
        --db-user "$OBSERVIUM_DB_USER" \
        --db-pass "$OBSERVIUM_DB_PASS" \
        --snmp-community "$SNMP_COMMUNITY" \
        --check-interval "$CHECK_INTERVAL" \
        --retry-interval "$RETRY_INTERVAL" \
        --max-attempts "$MAX_CHECK_ATTEMPTS" \
        --output-dir /etc/icinga2/conf.d/generated/ \
        2>&1 || echo "WARNING: Observium sync failed (non-fatal)"
fi

# ==================== Cron Setup ====================

echo "Setting up cron jobs..."

# Observium sync every 6 hours + on-demand trigger
cat > /etc/cron.d/icinga2-sync << 'EOF'
# Sync from Observium every 6 hours
0 */6 * * * root /usr/local/bin/sync-observium-cron.sh >> /var/log/icinga2/sync.log 2>&1

# Check for on-demand sync trigger every minute
* * * * * root test -f /root/data/start9/sync-trigger && /usr/local/bin/sync-observium-cron.sh >> /var/log/icinga2/sync.log 2>&1 && rm -f /root/data/start9/sync-trigger
EOF

# Create the cron wrapper script
cat > /usr/local/bin/sync-observium-cron.sh << CRONEOF
#!/bin/bash
# Only run if sync is enabled
SYNC_ENABLED=\$(yq -r '.["observium-sync-enabled"] // "false"' /root/data/start9/config.yaml 2>/dev/null)
if [ "\$SYNC_ENABLED" = "true" ]; then
    DB_HOST=\$(yq -r '.["observium-db-host"] // "10.0.60.125"' /root/data/start9/config.yaml)
    DB_USER=\$(yq -r '.["observium-db-user"] // "observium"' /root/data/start9/config.yaml)
    DB_PASS=\$(yq -r '.["observium-db-password"] // ""' /root/data/start9/config.yaml)
    SNMP=\$(yq -r '.["snmp-community"] // "10fir"' /root/data/start9/config.yaml)
    CI=\$(yq -r '.["check-interval"] // "300"' /root/data/start9/config.yaml)
    RI=\$(yq -r '.["retry-interval"] // "60"' /root/data/start9/config.yaml)
    MA=\$(yq -r '.["max-check-attempts"] // "3"' /root/data/start9/config.yaml)

    python3 /usr/local/bin/sync-observium.py \\
        --db-host "\$DB_HOST" \\
        --db-user "\$DB_USER" \\
        --db-pass "\$DB_PASS" \\
        --snmp-community "\$SNMP" \\
        --check-interval "\$CI" \\
        --retry-interval "\$RI" \\
        --max-attempts "\$MA" \\
        --output-dir /etc/icinga2/conf.d/generated/

    # Validate and reload Icinga2
    if icinga2 daemon -C 2>/dev/null; then
        kill -HUP \$(cat /run/icinga2/icinga2.pid 2>/dev/null) 2>/dev/null || true
        echo "\$(date): Sync completed and Icinga2 reloaded"
    else
        echo "\$(date): WARNING: Config validation failed after sync"
    fi
fi
CRONEOF
chmod +x /usr/local/bin/sync-observium-cron.sh

# ==================== Validate and Start ====================

echo "Validating Icinga2 configuration..."

# Stop the temporary MySQL (supervisor will restart it)
mysqladmin shutdown --socket=/var/run/mysqld/mysqld.sock -u root -p"${DB_PASS}" 2>/dev/null || true
wait $MYSQL_PID 2>/dev/null || true

echo "============================================"
echo "  Starting services via supervisord"
echo "============================================"

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
