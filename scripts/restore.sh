#!/bin/bash
shopt -s nullglob
# =============== 設定參數 ===============
COMPOSE_FILE="../docker-compose.staging.yml"
PROJECT_NAME="app"
BACKUP_ROOT="/home/eai/doh/backups"
LOG_FILE="${BACKUP_ROOT}/restore.log"

# 資料卷對應表
declare -A VOLUME_MAP
VOLUME_MAP["data1_projects_dh_STORAGE"]="/data1/projects/dh/STORAGE"
VOLUME_MAP["data1_tungma_doh_email-templates"]="/data1/tungma/doh/email-templates"

CONFIG_TARGET="/data1/projects/dh"

# 進度設定
TOTAL_STEPS=7
CURRENT_STEP=0
# ========================================

# 顏色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 函數
progress_start() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    PERCENT=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    printf "${BLUE}[%2d/%d] %-45s [ %3d%% ]${NC} " "$CURRENT_STEP" "$TOTAL_STEPS" "$1" "$PERCENT"
}

progress_skip() {
    echo -e "${GRAY}跳過${NC}" | tee -a "$LOG_FILE"
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

# 動畫
spinner() {
    local pid=$1
    local delay=0.15
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " %c  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# 檢查 docker
if ! docker info > /dev/null 2>&1; then
    error "Docker 無法使用，請檢查權限"
fi

# 列出備份
list_backups() {
    local backups=($(find "$BACKUP_ROOT" -name "*.tar.gz" -type f | sort -r))
    if [ ${#backups[@]} -eq 0 ]; then
        error "找不到備份檔！"
    fi
    
    echo "============================================"
    echo "可用備份："
    for i in "${!backups[@]}"; do
        local file=$(basename "${backups[$i]}")
        local date=${file#}
        date=${date%.tar.gz}
        date="${date:0:4}-${date:4:2}-${date:6:2} ${date:9:2}:${date:11:2}"
        printf " %2d) %s → %s\n" $((i+1)) "$date" "$file"
    done
    echo "============================================"
    SELECTED_BACKUP="${backups[0]}"
}

# 選擇備份
select_backup() {
    local backups=($(find "$BACKUP_ROOT" -name "*.tar.gz" -type f | sort -r))
    if [ ${#backups[@]} -eq 0 ]; then
        error "找不到任何備份檔！"
    fi
    
    echo "============================================"
    echo "可用備份："
    for i in "${!backups[@]}"; do
        local file=$(basename "${backups[$i]}")
        local date=${file#}
        date=${date%.tar.gz}
        date="${date:0:4}-${date:4:2}-${date:6:2} ${date:9:2}:${date:11:2}"
        printf " %2d) %s → %s\n" $((i+1)) "$date" "$file"
    done
    echo "============================================"
    
    read -p "選擇要還原的編號 (1-${#backups[@]}): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        error "無效選擇"
    fi
    
    SELECTED_BACKUP="${backups[$((choice-1))]}"
    log "已選擇：$(basename "$SELECTED_BACKUP")"
}

# 主流程
main() {
    clear
    echo "==================================================" | tee -a "$LOG_FILE"
    log "開始還原 Staging 環境"
    
    # Step 1: 選擇備份
    progress_start "選擇備份檔"
    select_backup
    progress_done
    
    # 安全警告
    echo
    warn() { echo -e "${YELLOW}[警告] $1${NC}" | tee -a "$LOG_FILE"; }
    warn "這將會："
    echo "   • 停止所有容器"
    echo "   • 刪除現有資料卷"
    echo "   • 覆蓋設定檔"
    echo "   • 匯入映像檔（docker load）"
    echo
    read -p "輸入 YES 確認還原: " confirm
    [[ "$confirm" == "YES" ]] || { error "已取消"; exit 0; }
    
    # Step 2: 停止服務
    progress_start "停止服務"
    docker compose -f "$COMPOSE_FILE" down -v >> "$LOG_FILE" 2>&1 || error "停止失敗"
    progress_done
    
    # Step 3: 解壓備份
    progress_start "解壓備份檔"
    TEMP_DIR="/tmp/restore_$$"
    mkdir -p "$TEMP_DIR"
    tar -xzf "$SELECTED_BACKUP" -C "$TEMP_DIR" >> "$LOG_FILE" 2>&1 || error "解壓失敗"
    EXTRACTED_DIR="$TEMP_DIR/$(basename "$SELECTED_BACKUP" .tar.gz)"
    progress_done
    
    # ──────────────────────────────────────────────
    # Step 4: 還原設定檔
    progress_start "還原設定檔"
    if [ -d "$EXTRACTED_DIR/config" ]; then
        cp -r "$EXTRACTED_DIR/config/"* "$CONFIG_TARGET/" >> "$LOG_FILE" 2>&1
        log "設定檔已還原至 $CONFIG_TARGET"
    fi
    progress_done
    
    # Step 5: 還原資料卷
    progress_start "還原資料卷"
    if [ -d "$EXTRACTED_DIR/volumes" ]; then
        for tarfile in "$EXTRACTED_DIR/volumes/"*.tar.gz; do
            [ -f "$tarfile" ] || continue
            filename=$(basename "$tarfile" .tar.gz)
            log "還原 $filename"
            
            if [[ "$filename" == "app_mysql_data_staging" ]]; then
                log "使用臨時容器還原 MySQL 資料卷..."
                
                # 移除舊 volume
                docker volume rm "${PROJECT_NAME}_mysql_data_staging" 2>/dev/null || true
                
                # 建立新 volume
                docker volume create "${PROJECT_NAME}_mysql_data_staging" >> "$LOG_FILE" 2>&1
                
                # 正確解壓：不 strip，直接把 _data 資料夾內容放進 volume 根目錄
                docker run --rm \
                    -v "${PROJECT_NAME}_mysql_data_staging:/restore" \
                    -v "$EXTRACTED_DIR/volumes:/backup" \
                    alpine \
                    sh -c "mkdir -p /restore && tar -xzf /backup/${filename}.tar.gz -C /restore" \
                    >> "$LOG_FILE" 2>&1 || error "還原 MySQL 資料卷失敗"
                
                log "MySQL 資料卷已還原至 volume: ${PROJECT_NAME}_mysql_data_staging"
                
            else
                if [[ -n "${VOLUME_MAP[$filename]}" ]]; then
                    target="${VOLUME_MAP[$filename]}"
                    mkdir -p "$(dirname "$target")"
                    tar -xzf "$tarfile" -C "$(dirname "$target")" --strip-components=1 >> "$LOG_FILE" 2>&1 || error "還原 $filename 失敗"
                else
                    log "跳過未知卷：$filename"
                fi
            fi
        done
    fi
    progress_done
    
    # Step 6: 匯入映像檔（正確偵測 *.tar）
    progress_start "匯入映像檔 (docker load)"
    
    if [ -d "$EXTRACTED_DIR/containers" ] && compgen -G "$EXTRACTED_DIR/containers/*.tar" > /dev/null; then
        for img_tar in "$EXTRACTED_DIR/containers/"*.tar; do
            log "載入 $(basename "$img_tar")"
            docker load -i "$img_tar" >> "$LOG_FILE" 2>&1 &
            load_pid=$!
            spinner $load_pid
            wait $load_pid && echo -n "完成" || error "載入 $(basename "$img_tar") 失敗"
            echo
        done
        progress_done
    else
        log "無映像檔需要載入"
        progress_skip
    fi
    progress_done
    
    # Step 7: 啟動服務
    progress_start "啟動服務"
    docker compose -f "$COMPOSE_FILE" up -d >> "$LOG_FILE" 2>&1 || error "啟動失敗"
    progress_done
    
    # 清理
    rm -rf "$TEMP_DIR"
    
    # 完成
    log "還原成功！"
    echo "備份來源：$(basename "$SELECTED_BACKUP")" | tee -a "$LOG_FILE"
    echo "請檢查服務：docker compose -f $COMPOSE_FILE ps" | tee -a "$LOG_FILE"
    echo "==================================================" | tee -a "$LOG_FILE"
}

main
