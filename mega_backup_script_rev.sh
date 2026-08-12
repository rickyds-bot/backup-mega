#!/bin/bash
# MEGA BACKUP - FULL TUNED VERSION (STABLE)

# === ENV (WAJIB UNTUK CRON) ===
export PATH=/usr/bin:/usr/local/bin:/bin

# === KONFIGURASI ===
LOG_BASE="/var/log/mega-backup"
DETAIL_DIR="$LOG_BASE/detail"
SUMMARY_LOG="$LOG_BASE/summary.log"
MAX_RETRY=3
DAY_NUM=$(date +%u)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOCK_FILE="/tmp/mega-backup.lock"

# === MEGA LOGIN (LEBIH AMAN) ===
MEGA_USER=$(tr -d '\n' < /root/.mega_user)
MEGA_PASS=$(tr -d '\n' < /root/.mega_pass)

# === LIMIT ===
CPU_LIMIT="30%"
SPEED_LIMIT_KB=5000
MAX_LOAD=3.5

mkdir -p "$DETAIL_DIR"

# === LOCK ===
if [ -f "$LOCK_FILE" ]; then
    echo "[INFO] Backup sudah berjalan. Keluar." | tee -a "$SUMMARY_LOG"
    exit 1
fi
trap "rm -f $LOCK_FILE" EXIT
touch "$LOCK_FILE"

# === CLEAN LOG ===
find "$DETAIL_DIR" -type f -mtime +30 -delete

# === CEK LOAD SERVER (TANPA bc - LEBIH AMAN) ===
LOAD=$(cut -d ' ' -f1 /proc/loadavg)
LOAD_INT=${LOAD%.*}

if [ "$LOAD_INT" -gt 3 ]; then
    echo "[SKIP] Server sibuk (Load: $LOAD)" | tee -a "$SUMMARY_LOG"
    exit 0
fi

# === AUTO LOGIN ===
ensure_mega_login() {
    mega-whoami > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "[INFO] Login ulang ke MEGA..." | tee -a "$SUMMARY_LOG"

        for i in 1 2 3; do
            mega-login "$MEGA_USER" "$MEGA_PASS" > /dev/null 2>&1 && return 0
            sleep 5
        done

        echo "[FAILED] Login MEGA gagal" | tee -a "$SUMMARY_LOG"
        return 1
    fi
    return 0
}

ensure_mega_login || exit 1

# === LIMIT SPEED ===
mega-speedlimit $SPEED_LIMIT_KB

# === DAFTAR BACKUP ===
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

# === FUNGSI SYNC ===
sync_with_retry() {
    local SRC_DIR="$1"
    local DST_DIR="$2"
    local log_detail="$DETAIL_DIR/sync_$(basename "$SRC_DIR")_${TIMESTAMP}.log"

    if [ ! -d "$SRC_DIR" ] || [ -z "$(ls -A "$SRC_DIR" 2>/dev/null)" ]; then
        echo "[ERROR] Folder invalid/kosong: $SRC_DIR" | tee -a "$SUMMARY_LOG"
        return 1
    fi

    echo "[START] $SRC_DIR → $DST_DIR" | tee -a "$SUMMARY_LOG" "$log_detail"

    for attempt in $(seq 1 $MAX_RETRY); do
        ensure_mega_login

        systemd-run --scope -p CPUQuota=$CPU_LIMIT -p IOWeight=10 \
        nice -n 19 ionice -c2 -n7 \
        mega-sync "$SRC_DIR" "$DST_DIR" >> "$log_detail" 2>&1

        if [ $? -eq 0 ]; then
            SIZE=$(du -sh "$SRC_DIR" 2>/dev/null | awk '{print $1}')
            echo "[SUCCESS] $SRC_DIR | Size: $SIZE" | tee -a "$SUMMARY_LOG"
            return 0
        else
            echo "[RETRY] Gagal ($attempt)" | tee -a "$log_detail"
            sleep 15
        fi
    done

    echo "[FAILED] $SRC_DIR" | tee -a "$SUMMARY_LOG"
    return 1
}

# === BATCH MODE (KHUSUS LIBRARY) ===
sync_library_batch() {
    local SRC_DIR="$1"
    local DST_DIR="$2"

    echo "[INFO] Batch sync library..." | tee -a "$SUMMARY_LOG"

    for sub in "$SRC_DIR"/*; do
        [ -d "$sub" ] || continue

        sync_with_retry "$sub" "$DST_DIR/$(basename "$sub")"
        sleep 30
    done
}

# === EKSEKUSI ===
if [ -n "$ENTRY" ]; then
    IFS=',' read -ra PAIRS <<< "$ENTRY"

    for pair in "${PAIRS[@]}"; do
        SRC_DIR="${pair%%:*}"
        DST_DIR="${pair##*:}"

        if [[ "$SRC_DIR" == *"library"* ]]; then
            sync_library_batch "$SRC_DIR" "$DST_DIR"
        else
            sync_with_retry "$SRC_DIR" "$DST_DIR"
        fi

        sleep 20
    done
else
    echo "[INFO] Tidak ada backup hari ini" | tee -a "$SUMMARY_LOG"
fi
