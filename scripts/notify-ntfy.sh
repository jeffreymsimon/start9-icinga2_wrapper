#!/bin/bash
# Icinga2 notification script — sends alerts to ntfy
# Called by Icinga2 NotificationCommand with environment variables:
#   NOTIFICATIONTYPE, HOSTNAME, HOSTSTATE, HOSTOUTPUT,
#   SERVICENAME, SERVICESTATE, SERVICEOUTPUT, LONGDATETIME
#
# ntfy config is read from the StartOS config.yaml via environment variables
# set in the Icinga2 notification object.

CONFIG_FILE="/root/data/start9/config.yaml"

# Read ntfy settings from config
NTFY_SERVER=$(yq -r '.["ntfy-server-url"] // "https://ntfy.sh"' "$CONFIG_FILE" 2>/dev/null)
NTFY_TOPIC=$(yq -r '.["ntfy-topic"] // ""' "$CONFIG_FILE" 2>/dev/null)
NTFY_USERNAME=$(yq -r '.["ntfy-username"] // ""' "$CONFIG_FILE" 2>/dev/null)
NTFY_PASSWORD=$(yq -r '.["ntfy-password"] // ""' "$CONFIG_FILE" 2>/dev/null)
NTFY_DEFAULT_PRIORITY=$(yq -r '.["ntfy-priority"] // "4"' "$CONFIG_FILE" 2>/dev/null)

if [ -z "$NTFY_TOPIC" ]; then
    echo "ERROR: ntfy topic not configured, skipping notification"
    exit 1
fi

# Determine notification type (host vs service)
if [ -n "$SERVICENAME" ]; then
    TYPE="service"
    STATE="$SERVICESTATE"
    OUTPUT="$SERVICEOUTPUT"
    SUBJECT="${NOTIFICATIONTYPE}: ${HOSTNAME}/${SERVICENAME} is ${STATE}"
else
    TYPE="host"
    STATE="$HOSTSTATE"
    OUTPUT="$HOSTOUTPUT"
    SUBJECT="${NOTIFICATIONTYPE}: ${HOSTNAME} is ${STATE}"
fi

# Map state to ntfy priority and tags
case "$STATE" in
    CRITICAL|DOWN)
        PRIORITY=5
        TAGS="rotating_light,${TYPE}"
        ;;
    WARNING)
        PRIORITY="$NTFY_DEFAULT_PRIORITY"
        TAGS="warning,${TYPE}"
        ;;
    OK|UP)
        PRIORITY=3
        TAGS="white_check_mark,${TYPE}"
        ;;
    UNKNOWN)
        PRIORITY="$NTFY_DEFAULT_PRIORITY"
        TAGS="grey_question,${TYPE}"
        ;;
    *)
        PRIORITY="$NTFY_DEFAULT_PRIORITY"
        TAGS="${TYPE}"
        ;;
esac

# Build message body
if [ "$TYPE" = "service" ]; then
    BODY="${NOTIFICATIONTYPE} - ${HOSTNAME}/${SERVICENAME}
State: ${STATE}
Output: ${OUTPUT}
Time: ${LONGDATETIME}"
else
    BODY="${NOTIFICATIONTYPE} - ${HOSTNAME}
State: ${STATE}
Output: ${OUTPUT}
Time: ${LONGDATETIME}"
fi

# Build curl command
CURL_ARGS=(
    -s
    -o /dev/null
    -w "%{http_code}"
    -H "Title: ${SUBJECT}"
    -H "Priority: ${PRIORITY}"
    -H "Tags: ${TAGS}"
    -d "${BODY}"
)

# Add auth if configured
if [ -n "$NTFY_USERNAME" ] && [ -n "$NTFY_PASSWORD" ]; then
    CURL_ARGS+=(-u "${NTFY_USERNAME}:${NTFY_PASSWORD}")
fi

HTTP_CODE=$(curl "${CURL_ARGS[@]}" "${NTFY_SERVER}/${NTFY_TOPIC}" 2>/dev/null)

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: ntfy notification failed (HTTP ${HTTP_CODE}) for ${SUBJECT}"
    exit 1
fi

echo "OK: ntfy notification sent for ${SUBJECT}"
exit 0
