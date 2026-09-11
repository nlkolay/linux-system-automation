#!/bin/bash
set -u

SOURCE_DIRECTORY="${1:-/mnt/source_storage/}"
TARGET_DIRECTORY="${2:-/mnt/destination_storage/}"
MONITORED_DEVICE="${3:-sdc}"

MAXIMUM_ALLOWED_TEMPERATURE=52
EXECUTION_LOG="/var/log/safe_disk_sync.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Инициализация безопасной синхронизации данных." | tee -a "$EXECUTION_LOG"
echo "Источник: $SOURCE_DIRECTORY | Приемник: $TARGET_DIRECTORY" | tee -a "$EXECUTION_LOG"

if [ ! -d "$SOURCE_DIRECTORY" ] || [ ! -d "$TARGET_DIRECTORY" ]; then
    echo "Ошибка: Директории источника или назначения недоступны." | tee -a "$EXECUTION_LOG"
    exit 1
fi

rsync -ahvP --numeric-ids "$SOURCE_DIRECTORY" "$TARGET_DIRECTORY" >> "$EXECUTION_LOG" 2>&1 &
SYNC_PROCESS_ID=$!

check_hardware_health() {
    local device_name="$1"
    local raw_temp
    raw_temp=$(smartctl -A "/dev/$device_name" 2>/dev/null | grep -i "Temperature_Celsius" | awk '{print $10}')

    if [ -n "$raw_temp" ] && [ "$raw_temp" -ge "$MAXIMUM_ALLOWED_TEMPERATURE" ]; then
        echo "Критическое предупреждение: Превышен температурный порог накопителя $device_name ($raw_temp °C)." | tee -a "$EXECUTION_LOG"
        return 1
    fi

    local pending_sectors
    pending_sectors=$(smartctl -A "/dev/$device_name" 2>/dev/null | grep -i "Current_Pending_Sector" | awk '{print $10}')

    if [ -n "$pending_sectors" ] && [ "$pending_sectors" -gt 0 ]; then
        echo "Критическое предупреждение: Обнаружены нестабильные секторы ($pending_sectors) на $device_name." | tee -a "$EXECUTION_LOG"
        return 1
    fi

    return 0
}

while kill -0 "$SYNC_PROCESS_ID" 2>/dev/null; do
    if ! check_hardware_health "$MONITORED_DEVICE"; then
        echo "Аварийная остановка процесса синхронизации (PID: $SYNC_PROCESS_ID)." | tee -a "$EXECUTION_LOG"
        kill -15 "$SYNC_PROCESS_ID"
        sleep 5
        if kill -0 "$SYNC_PROCESS_ID" 2>/dev/null; then
            kill -9 "$SYNC_PROCESS_ID"
        fi
        exit 2
    fi
    sleep 30
done

wait "$SYNC_PROCESS_ID"
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Синхронизация успешно завершена." | tee -a "$EXECUTION_LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Синхронизация завершилась с кодом ошибки: $EXIT_CODE." | tee -a "$EXECUTION_LOG"
fi

exit "$EXIT_CODE"
