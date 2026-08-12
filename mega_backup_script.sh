#!/bin/bash
# Final Backup Script ke MEGA (multi-folder, sesuai hari)
# Lokasi log: /var/log/mega-backup/

# === KONFIGURASI ===
LOG_BASE="/var/log/mega-backup"
DETAIL_DIR="$LOG_BASE/detail"
SUMMARY_LOG="$LOG_BASE/summary.log"
MAX_RETRY=3
DAY_NUM=$(date +%u)   # 1=Senin ... 7=Minggu

mkdir -p "$DETAIL_DIR"

# === DAFTAR FOLDER BACKUP PER HARI ===
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

# === FUNGSI UPLOAD DENGAN RETRY ===
upload_with_retry() {
    local SRC_DIR="$1"
    local DST_DIR="$2"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_detail="$DETAIL_DIR/$(basename $DST_DIR)_${timestamp}.log"

    echo "[${timestamp}] Mulai backup $SRC_DIR → $DST_DIR" | tee -a "$SUMMARY_LOG" "$log_detail"

    # Catat file & ukuran sebelum upload
    echo "Daftar file yang akan diupload:" >> "$log_detail"
    find "$SRC_DIR" -type f -exec du -h {} \; | sort -h >> "$log_detail"
    echo "------------------------------------------------------------" >> "$log_detail"

    local attempt=1
    while [ $attempt -le $MAX_RETRY ]; do
        echo "[${timestamp}] Percobaan $attempt → $SRC_DIR → $DST_DIR" | tee -a "$log_detail"

        # Upload, filter warning OS
        mega-put -c "$SRC_DIR" "$DST_DIR" 2>&1 | grep -v "Your Operative System" >> "$log_detail"
        status=$?

        if [ $status -eq 0 ]; then
            size=$(du -sh "$SRC_DIR" | awk '{print $1}')
            echo "[${timestamp}] [SUCCESS] $SRC_DIR → $DST_DIR | Size: $size | Log: $log_detail" \
                | tee -a "$SUMMARY_LOG" "$log_detail"
            return 0
        else
            echo "[${timestamp}] Gagal percobaan $attempt" | tee -a "$log_detail"
            attempt=$((attempt+1))
            sleep 5
        fi
    done

    echo "[${timestamp}] [FAILED] $SRC_DIR → $DST_DIR setelah $MAX_RETRY percobaan | Log: $log_detail" \
        | tee -a "$SUMMARY_LOG" "$log_detail"
    return 1
}

# === JALANKAN BACKUP SESUAI HARI ===
if [ -n "$ENTRY" ]; then
    IFS=',' read -ra PAIRS <<< "$ENTRY"
    for pair in "${PAIRS[@]}"; do
        SRC_DIR="${pair%%:*}"
        DST_DIR="${pair##*:}"
        upload_with_retry "$SRC_DIR" "$DST_DIR"
    done
else
    echo "[ $(date +"%Y-%m-%d %H:%M:%S") ] Tidak ada folder untuk hari ke-$DAY_NUM" | tee -a "$SUMMARY_LOG"
fi
