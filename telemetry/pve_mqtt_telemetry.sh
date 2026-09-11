#!/bin/bash
set -u

MQTT_HOST="${MQTT_HOST:-192.168.1.174}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-pve_agent}"
MQTT_PASS="${MQTT_PASS:-agent_secret_password}"

NODE_NAME="pve"
DEVICE_ID="pve_cluster_node"
DEVICE_NAME="Proxmox Server"

send_registration() {
    local sensor_id="$1"
    local friendly_name="$2"
    local unit="$3"
    local device_class="$4"
    local icon="$5"

    local discovery_topic="homeassistant/sensor/${NODE_NAME}/${sensor_id}/config"
    local state_topic="${NODE_NAME}/telemetry/${sensor_id}"

    local payload
    payload=$(cat <<EOF
{
  "name": "${friendly_name}",
  "state_topic": "${state_topic}",
  "unit_of_measurement": "${unit}",
  "device_class": "${device_class}",
  "icon": "${icon}",
  "unique_id": "${NODE_NAME}_${sensor_id}",
  "device": {
    "identifiers": ["${DEVICE_ID}"],
    "name": "${DEVICE_NAME}",
    "model": "Ryzen Embedded Platform",
    "manufacturer": "Custom Industrial Hardware"
  }
}
EOF
)
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "$discovery_topic" -m "$payload" -r
}

publish_metric() {
    local sensor_id="$1"
    local value="$2"
    local state_topic="${NODE_NAME}/telemetry/${sensor_id}"

    if [ -n "$value" ]; then
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
            -t "$state_topic" -m "$value"
    fi
}

initialize_environment() {
    send_registration "cpu_load" "CPU Total Load" "%" "" "mdi:cpu-64-bit"
    send_registration "ram_usage" "RAM Utilization" "%" "" "mdi:memory"
    send_registration "temp_sdc" "Temperature Main Storage" "°C" "temperature" "mdi:thermometer"
    send_registration "temp_sdi" "Temperature Auxiliary Storage" "°C" "temperature" "mdi:thermometer"
    send_registration "storage_pool_usage" "Storage Pool Capacity" "%" "" "mdi:database"
    send_registration "system_uptime" "Node Uptime" "days" "" "mdi:clock-outline"
}

collect_and_send() {
    local cpu_load
    cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')

    local ram_usage
    ram_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')

    local temp_sdc
    temp_sdc=$(smartctl -A /dev/sdc 2>/dev/null | grep -i "Temperature_Celsius" | awk '{print $10}')

    local temp_sdi
    temp_sdi=$(smartctl -A /dev/sdi 2>/dev/null | grep -i "Temperature_Celsius" | awk '{print $10}')

    local pool_usage
    pool_usage=$(df -P /mnt/media_pool 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')

    local uptime_days
    uptime_days=$(awk '{print int($1/86400)}' /proc/uptime)

    publish_metric "cpu_load" "$cpu_load"
    publish_metric "ram_usage" "$ram_usage"
    publish_metric "temp_sdc" "$temp_sdc"
    publish_metric "temp_sdi" "$temp_sdi"
    publish_metric "storage_pool_usage" "$pool_usage"
    publish_metric "system_uptime" "$uptime_days"
}

initialize_environment

while true; do
    collect_and_send
    sleep 60
done
