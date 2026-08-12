#!/bin/bash
# FINAL BACKUP: MEGA-SYNC ONLY (NO SNAPSHOT)

# === KONFIGURASI ===
LOG_BASE="/var/log/mega-backup"
DETAIL_DIR="$LOG_BASE/detail"
SUMMARY_LOG="$LOG_BASE/summary.log"
MAX_RETRY=3
DAY_NUM=$(date +%u)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOCK_FILE="/tmp/mega-backup.lock"

mkdir -p "$DETAIL_DIR"

# === LOCK (ANTI DOUBLE RUN) ===
if [ -f "$LOCK_FILE" ]; then
    echo "[INFO] Backup sudah berjalan. Keluar." | tee -a "$SUMMARY_LOG"
    exit 1
fi
trap "rm -f $LOCK_FILE" EXIT
touch "$LOCK_FILE"

# === CLEANUP LOG > 30 HARI ===
find "$DETAIL_DIR" -type f -mtime +30 -delete

# === CEK KONEKSI MEGA ===
mega-whoami > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[ERROR] Tidak terhubung ke MEGA" | tee -a "$SUMMARY_LOG"
    exit 1
fi

# === DAFTAR FOLDER BACKUP ===
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
    local log_detail="$DETAIL_DIR/sync_$(basename $SRC_DIR)_${TIMESTAMP}.log"

    # === VALIDASI FOLDER ===
    if [ ! -d "$SRC_DIR" ]; then
        echo "[ERROR] Folder tidak ditemukan: $SRC_DIR" | tee -a "$SUMMARY_LOG"
        return 1
    fi

    if [ -z "$(ls -A $SRC_DIR 2>/dev/null)" ]; then
        echo "[ERROR] Folder kosong / mount error: $SRC_DIR" | tee -a "$SUMMARY_LOG"
        return 1
    fi

    echo "[${TIMESTAMP}] SYNC $SRC_DIR → $DST_DIR" | tee -a "$SUMMARY_LOG" "$log_detail"

    local attempt=1
    while [ $attempt -le $MAX_RETRY ]; do
        # PRIORITY RENDAH (biar tidak ganggu server)
        nice -n 19 ionice -c2 -n7 mega-sync "$SRC_DIR" "$DST_DIR" >> "$log_detail" 2>&1
        status=$?

        if [ $status -eq 0 ]; then
            SIZE=$(du -sh "$SRC_DIR" 2>/dev/null | awk '{print $1}')
            echo "[SUCCESS] $SRC_DIR | Size: $SIZE" | tee -a "$SUMMARY_LOG"
            return 0
        else
            echo "[RETRY] Sync gagal ($attempt)" | tee -a "$log_detail"
            attempt=$((attempt+1))
            sleep 15
        fi
    done

    echo "[FAILED] SYNC $SRC_DIR" | tee -a "$SUMMARY_LOG"
    return 1
}

# === EKSEKUSI ===
if [ -n "$ENTRY" ]; then
    IFS=',' read -ra PAIRS <<< "$ENTRY"

    for pair in "${PAIRS[@]}"; do
        SRC_DIR="${pair%%:*}"
        DST_DIR="${pair##*:}"

        sync_with_retry "$SRC_DIR" "$DST_DIR"
        sleep 10   # anti rate limit
    done
else
    echo "[INFO] Tidak ada backup hari ini" | tee -a "$SUMMARY_LOG"
fi
