FROM ubuntu:24.04

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install base packages first (before adding external repos)
RUN apt-get update && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Add Icinga2 official apt repository
RUN curl -fsSL https://packages.icinga.com/icinga.key | gpg --dearmor -o /etc/apt/keyrings/icinga.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/icinga.gpg] https://packages.icinga.com/ubuntu icinga-noble main" > /etc/apt/sources.list.d/icinga.list

# Install system packages first (from Ubuntu repos)
RUN apt-get update && apt-get install -y \
    apache2 libapache2-mod-php \
    php-mysql php-gd php-curl php-intl php-xml php-mbstring php-imagick php-cli \
    mysql-server mysql-client \
    monitoring-plugins nagios-plugins-contrib \
    fping snmp dnsutils nmap iputils-ping traceroute \
    supervisor cron \
    yq jq python3 python3-pymysql \
    && rm -rf /var/lib/apt/lists/*

# Install Icinga2 + IcingaWeb2 from official Icinga repo
# Pin to Icinga repo to avoid version conflicts between Ubuntu and Icinga packages
RUN apt-get update && apt-get install -y \
    icinga2 icinga2-ido-mysql \
    icingaweb2 \
    && rm -rf /var/lib/apt/lists/*

# Enable required Apache modules
RUN a2enmod php8.3 rewrite headers

# Disable default Apache site
RUN a2dissite 000-default.conf 2>/dev/null || true

# Set capabilities for ICMP tools (allows ping without root in LXC)
RUN setcap cap_net_raw+ep /usr/bin/fping || true
RUN setcap cap_net_raw+ep /bin/ping || true

# Fix MySQL user home directory (Ubuntu 24.04 LXC workaround)
RUN usermod -d /root/data/mysql mysql 2>/dev/null || true
RUN mkdir -p /var/lib/mysql && chown mysql:mysql /var/lib/mysql

# Create directory structure
RUN mkdir -p /root/data/start9 /root/data/mysql /root/data/icinga2 \
    /var/log/supervisor /var/run/icinga2 /var/run/mysqld \
    /etc/icinga2/conf.d/generated \
    /etc/icingaweb2/modules/monitoring \
    /etc/icingaweb2/enabledModules

# Fix permissions
RUN chown -R nagios:nagios /var/run/icinga2
RUN chown mysql:mysql /var/run/mysqld

# Copy configuration files
COPY sites-enabled/icingaweb2.conf /etc/apache2/sites-enabled/icingaweb2.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy Observium-compatible Nagios plugins
COPY scripts/check_curl /usr/lib/nagios/plugins/check_curl
COPY scripts/check_cloudflare_tunnel /usr/lib/nagios/plugins/check_cloudflare_tunnel
COPY scripts/check_dell_smart /usr/lib/nagios/plugins/check_dell_smart
RUN chmod +x /usr/lib/nagios/plugins/check_curl /usr/lib/nagios/plugins/check_cloudflare_tunnel /usr/lib/nagios/plugins/check_dell_smart

# Copy entrypoint and scripts (bust cache on entrypoint changes)
COPY docker_entrypoint.sh /usr/local/bin/docker_entrypoint.sh
COPY scripts/sync-observium.py /usr/local/bin/sync-observium.py
COPY scripts/notify-ntfy.sh /usr/local/bin/notify-ntfy.sh
RUN chmod +x /usr/local/bin/docker_entrypoint.sh /usr/local/bin/sync-observium.py /usr/local/bin/notify-ntfy.sh

# Copy backup/restore scripts
RUN mkdir -p /assets/compat
COPY assets/compat/backup.sh /assets/compat/backup.sh
COPY assets/compat/restore.sh /assets/compat/restore.sh
RUN chmod +x /assets/compat/*.sh

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/docker_entrypoint.sh"]
