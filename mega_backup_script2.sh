#!/bin/bash
# HYBRID BACKUP: Incremental (mega-sync) + Snapshot Mingguan (tar.gz)

# === KONFIGURASI ===
LOG_BASE="/var/log/mega-backup"
DETAIL_DIR="$LOG_BASE/detail"
SUMMARY_LOG="$LOG_BASE/summary.log"
SNAPSHOT_DIR="/tmp/mega_snapshot"
MAX_RETRY=3
DAY_NUM=$(date +%u)   # 1=Senin ... 7=Minggu
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOCK_FILE="/tmp/mega-backup.lock"

mkdir -p "$DETAIL_DIR" "$SNAPSHOT_DIR"

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

# === FUNGSI SYNC (INCREMENTAL) ===
sync_with_retry() {
    local SRC_DIR="$1"
    local DST_DIR="$2"
    local log_detail="$DETAIL_DIR/sync_$(basename $DST_DIR)_${TIMESTAMP}.log"

    if [ ! -d "$SRC_DIR" ]; then
        echo "[ERROR] Folder tidak ditemukan: $SRC_DIR" | tee -a "$SUMMARY_LOG"
        return 1
    fi

    echo "[${TIMESTAMP}] SYNC $SRC_DIR → $DST_DIR" | tee -a "$SUMMARY_LOG" "$log_detail"

    local attempt=1
    while [ $attempt -le $MAX_RETRY ]; do
        mega-sync "$SRC_DIR" "$DST_DIR" >> "$log_detail" 2>&1
        status=$?

        if [ $status -eq 0 ]; then
            echo "[SUCCESS] SYNC $SRC_DIR" | tee -a "$SUMMARY_LOG"
            return 0
        else
            echo "[RETRY] Sync gagal ($attempt)" | tee -a "$log_detail"
            attempt=$((attempt+1))
            sleep 10
        fi
    done

    echo "[FAILED] SYNC $SRC_DIR" | tee -a "$SUMMARY_LOG"
    return 1
}

# === FUNGSI SNAPSHOT (MINGGUAN) ===
snapshot_and_upload() {
    local SRC_DIR="$1"
    local DST_DIR="$2"
    local NAME=$(basename "$SRC_DIR")
    local ARCHIVE="$SNAPSHOT_DIR/${NAME}_${TIMESTAMP}.tar.gz"
    local log_detail="$DETAIL_DIR/snapshot_${NAME}_${TIMESTAMP}.log"

    echo "[${TIMESTAMP}] SNAPSHOT $SRC_DIR" | tee -a "$SUMMARY_LOG" "$log_detail"

    if [ ! -d "$SRC_DIR" ]; then
        echo "[ERROR] Folder tidak ditemukan: $SRC_DIR" | tee -a "$SUMMARY_LOG"
        return 1
    fi

    # Compress
    tar -czf "$ARCHIVE" "$SRC_DIR" >> "$log_detail" 2>&1

    # Upload dengan retry
    local attempt=1
    while [ $attempt -le $MAX_RETRY ]; do
        mega-put "$ARCHIVE" "$DST_DIR" >> "$log_detail" 2>&1
        status=$?

        if [ $status -eq 0 ]; then
            echo "[SUCCESS] SNAPSHOT $ARCHIVE" | tee -a "$SUMMARY_LOG"
            rm -f "$ARCHIVE"
            return 0
        else
            echo "[RETRY] Upload snapshot gagal ($attempt)" | tee -a "$log_detail"
            attempt=$((attempt+1))
            sleep 15
        fi
    done

    echo "[FAILED] SNAPSHOT $SRC_DIR" | tee -a "$SUMMARY_LOG"
    return 1
}

# === EKSEKUSI ===
if [ -n "$ENTRY" ]; then
    IFS=',' read -ra PAIRS <<< "$ENTRY"

    for pair in "${PAIRS[@]}"; do
        SRC_DIR="${pair%%:*}"
        DST_DIR="${pair##*:}"

        if [ "$DAY_NUM" -eq 7 ]; then
            # Minggu → snapshot
            snapshot_and_upload "$SRC_DIR" "$DST_DIR"
        else
            # Hari biasa → incremental
            sync_with_retry "$SRC_DIR" "$DST_DIR"
        fi

        sleep 10  # anti rate limit
    done
else
    echo "[INFO] Tidak ada backup hari ini" | tee -a "$SUMMARY_LOG"
fi
