#!/bin/bash
# =====================================================
# MEGA INCREMENTAL BACKUP - ULTRA STABLE VERSION
# Khusus server lama / koneksi tidak stabil
# =====================================================

# === ENV ===
export PATH=/usr/bin:/usr/local/bin:/bin

# =====================================================
# KONFIGURASI
# =====================================================
LOG_BASE="/var/log/mega-backup"
DETAIL_DIR="$LOG_BASE/detail"
SUMMARY_LOG="$LOG_BASE/summary.log"
STATE_DIR="/var/lib/mega-backup"
LOCK_FILE="/tmp/mega-backup.lock"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DAY_NUM=$(date +%u)
MAX_RETRY=3
SPEED_LIMIT_KB=5000
MAX_LOAD=3.5

# === LOGIN ===
MEGA_USER=$(tr -d '\n' < /root/.mega_user)
MEGA_PASS=$(tr -d '\n' < /root/.mega_pass)

mkdir -p "$DETAIL_DIR"
mkdir -p "$STATE_DIR"

# =====================================================
# LOCK FILE
# =====================================================
if [ -f "$LOCK_FILE" ]; then
    echo "[$(date)] [INFO] Backup masih berjalan" | tee -a "$SUMMARY_LOG"
    exit 1
fi

trap "rm -f $LOCK_FILE" EXIT

touch "$LOCK_FILE"

# =====================================================
# CLEAN OLD LOG
# =====================================================
find "$DETAIL_DIR" -type f -mtime +30 -delete

# =====================================================
# CEK LOAD SERVER
# =====================================================
LOAD=$(cut -d ' ' -f1 /proc/loadavg)
LOAD_INT=${LOAD%.*}

if [ "$LOAD_INT" -gt 3 ]; then
    echo "[$(date)] [SKIP] Load server tinggi: $LOAD" | tee -a "$SUMMARY_LOG"
    exit 0
fi

# =====================================================
# RESET MEGA DAEMON
# =====================================================
reset_mega() {
    pkill -9 mega-cmd-server > /dev/null 2>&1
    pkill -9 mega-exec > /dev/null 2>&1
    pkill -9 mega-put > /dev/null 2>&1
    sleep 3

    rm -rf /tmp/megaCmd*

    mega-cmd-server --do-not-log-to-stdout > /dev/null 2>&1 &

    sleep 10
}

# =====================================================
# LOGIN MEGA
# =====================================================
ensure_login() {

    timeout 30 mega-whoami > /dev/null 2>&1

    if [ $? -ne 0 ]; then

        echo "[$(date)] [INFO] Login ulang MEGA" | tee -a "$SUMMARY_LOG"

        for i in 1 2 3; do

            timeout 120 mega-login "$MEGA_USER" "$MEGA_PASS" > /dev/null 2>&1

            if [ $? -eq 0 ]; then
                return 0
            fi

            sleep 10
        done

        echo "[$(date)] [FAILED] Login MEGA gagal" | tee -a "$SUMMARY_LOG"
        return 1
    fi

    return 0
}

# =====================================================
# LIMIT SPEED
# =====================================================
set_speed_limit() {
    mega-speedlimit $SPEED_LIMIT_KB > /dev/null 2>&1
}

# =====================================================
# DAFTAR BACKUP
# =====================================================
case $DAY_NUM in
  1) ENTRY="/data2/finance/share:/backup_finance" ;;
  2) ENTRY="/data2/umum:/backup_umum" ;;
  3) ENTRY="/data2/tender/share:/backup_tender,/data1/library/share:/backup_library" ;;
  4) ENTRY="/data2/public/share:/backup_public" ;;
  5) ENTRY="/data2/secretary/share:/backup_secretary,/data2/legal/share:/backup_legal" ;;
  6) ENTRY="/data1/planning/share:/backup_planning" ;;
  7) ENTRY="/data2/project/share:/backup_project,/data2/qs/share:/backup_qs" ;;
  *) ENTRY="" ;;
esac

# =====================================================
# UPLOAD FILE
# =====================================================
upload_file() {

    local FILE="$1"
    local REMOTE_DIR="$2"
    local LOGFILE="$3"

    for attempt in $(seq 1 $MAX_RETRY); do

        timeout 12h mega-put "$FILE" "$REMOTE_DIR" >> "$LOGFILE" 2>&1

        if [ $? -eq 0 ]; then
            return 0
        fi

        echo "[$(date)] [RETRY] $(basename "$FILE") attempt $attempt" >> "$LOGFILE"

        reset_mega
        ensure_login

        sleep 15
    done

    return 1
}

# =====================================================
# INCREMENTAL BACKUP
# =====================================================
incremental_backup() {

    local SRC_DIR="$1"
    local DST_DIR="$2"

    local JOB_NAME
    JOB_NAME=$(echo "$SRC_DIR" | sed 's#/#_#g')

    local STATE_FILE="$STATE_DIR/${JOB_NAME}.txt"

    local LOGFILE="$DETAIL_DIR/$(basename "$SRC_DIR")_${TIMESTAMP}.log"

    touch "$STATE_FILE"

    echo "[$(date)] [START] $SRC_DIR -> $DST_DIR" | tee -a "$SUMMARY_LOG" "$LOGFILE"

    find "$SRC_DIR" -type f | while read FILE; do

        if [ ! -f "$FILE" ]; then
            continue
        fi

        FILE_HASH=$(stat -c "%Y_%s" "$FILE")

        if grep -Fq "$FILE_HASH|$FILE" "$STATE_FILE"; then
            continue
        fi

        echo "[$(date)] [UPLOAD] $FILE" >> "$LOGFILE"

        upload_file "$FILE" "$DST_DIR" "$LOGFILE"

        if [ $? -eq 0 ]; then

            echo "$FILE_HASH|$FILE" >> "$STATE_FILE"

            echo "[$(date)] [SUCCESS] $FILE" >> "$LOGFILE"

        else

            echo "[$(date)] [FAILED] $FILE" >> "$LOGFILE"

        fi

        sleep 2

    done

    echo "[$(date)] [DONE] $SRC_DIR" | tee -a "$SUMMARY_LOG"
}

# =====================================================
# MAIN
# =====================================================
reset_mega

ensure_login || exit 1

set_speed_limit

if [ -n "$ENTRY" ]; then

    IFS=',' read -ra PAIRS <<< "$ENTRY"

    for pair in "${PAIRS[@]}"; do

        SRC_DIR="${pair%%:*}"
        DST_DIR="${pair##*:}"

        incremental_backup "$SRC_DIR" "$DST_DIR"

        sleep 20

    done

else

    echo "[$(date)] [INFO] Tidak ada backup hari ini" | tee -a "$SUMMARY_LOG"

fi

# =====================================================
# CLEAN EXIT
# =====================================================
pkill -9 mega-cmd-server > /dev/null 2>&1
pkill -9 mega-exec > /dev/null 2>&1
pkill -9 mega-put > /dev/null 2>&1

exit 0

