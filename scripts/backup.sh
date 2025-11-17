#!/bin/bash

# =============== 設定參數 ===============
COMPOSE_FILE="../docker-compose.staging.yml"
PROJECT_NAME="app"
BACKUP_ROOT="/home/eai/doh/backups"
DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_ROOT}/${DATE}"
FINAL_BACKUP="${BACKUP_ROOT}/${DATE}.tar.gz"
LOG_FILE="${BACKUP_ROOT}/backup.log"

VOLUMES=("app_mysql_data_staging" "/data1/projects/dh/STORAGE" "/data1/tungma/doh/email-templates")
CONFIG_DIRS=("./web-service" "./nginx" "docker-compose.staging.yml")

# 進度設定
TOTAL_STEPS=5
CURRENT_STEP=0
# ========================================

# 顏色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 進度函數
progress_start() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  PERCENT=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
  printf "${BLUE}[%2d/%d] %-45s [ %3d%% ]${NC} " "$CURRENT_STEP" "$TOTAL_STEPS" "$1" "$PERCENT"
}

progress_done() {
  echo -e "${GREEN}完成${NC}" | tee -a "$LOG_FILE"
}

log() {
  echo -e "${PURPLE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

error() {
  echo -e "${RED}失敗 → $1${NC}" | tee -a "$LOG_FILE"
  exit 1
}

# 開始
clear
echo "==================================================" | tee -a "$LOG_FILE"
log "開始完整備份 Staging 環境 ($DATE)"

# Step 1: 停止服務
progress_start "停止 Docker 服務"
docker compose -f "$COMPOSE_FILE" down >> "$LOG_FILE" 2>&1 && progress_done || error "停止服務失敗"

# Step 2: 備份資料卷
progress_start "備份資料卷"
mkdir -p "$BACKUP_DIR/volumes"

for vol in "${VOLUMES[@]}"; do
if [[ "$vol" == /* ]]; then
    src="$vol"
    name=$(echo "$vol" | tr '/' '_' | sed 's/^_//')
  else
    # 關鍵：加上 PROJECT_NAME 前綴
    full_vol_name="${PROJECT_NAME}_$vol"
    src=$(docker volume inspect --format '{{ .Mountpoint }}' "$full_vol_name" 2>/dev/null || echo "")
    [[ -z "$src" ]] && { log "Volume $full_vol_name 不存在，跳過"; continue; }
    name="$full_vol_name"  # 這裡也要用完整名稱
  fi

  size_mb=$(du -sm "$src" 2>/dev/null | cut -f1)
  log "壓縮 $src ($size_mb MB) → $name.tar.gz"

  # 背景壓縮 + 動畫
  tar -czf "$BACKUP_DIR/volumes/${name}.tar.gz" -C "$(dirname "$src")" "$(basename "$src")" > /dev/null 2>&1 &
  tar_pid=$!
  wait $tar_pid && echo -n "完成" || error "備份 $name 失敗"
  echo
done
progress_done

# Step 3: 備份設定檔
progress_start "備份設定檔"
mkdir -p "$BACKUP_DIR/config"
for item in "${CONFIG_DIRS[@]}"; do
  [[ -e "$item" ]] || continue
  cp -r "$item" "$BACKUP_DIR/config/" >> "$LOG_FILE" 2>&1
done
progress_done

# Step 4: 匯出容器映像
progress_start "匯出容器映像"
mkdir -p "$BACKUP_DIR/containers"
for service in admin-dashboard-staging web-service-staging mysql nginx; do
  image=$(docker compose -f "$COMPOSE_FILE" config --images | grep "$service" | awk '{print $1}')
  [[ -z "$image" ]] && continue
  safe_name=$(echo "$service" | tr '-' '_')
  log "匯出 $image"
  docker save "$image" -o "$BACKUP_DIR/containers/${safe_name}.tar" >> "$LOG_FILE" 2>&1 &
  save_pid=$!
  wait $save_pid
  echo -n "完成"
  echo
done
progress_done

# Step 5: 壓縮完整備份
progress_start "壓縮完整備份檔"
total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
log "壓縮中 ($total_size)..."

tar -czf "$FINAL_BACKUP" -C "$BACKUP_ROOT" "${DATE}" > /dev/null 2>&1 &
tar_pid=$!
wait $tar_pid && rm -rf "$BACKUP_DIR" || error "最終壓縮失敗"
progress_done

log "啟動服務..."
docker compose -f "$COMPOSE_FILE" up -d >> "$LOG_FILE" 2>&1
progress_done

# 完成
log "備份成功！"
final_size=$(du -h "$FINAL_BACKUP" | cut -f1)
echo "備份檔：$FINAL_BACKUP" | tee -a "$LOG_FILE"
echo "檔案大小：$final_size" | tee -a "$LOG_FILE"
echo "==================================================" | tee -a "$LOG_FILE"

