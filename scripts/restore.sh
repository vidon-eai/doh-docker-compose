#!/bin/bash

set -euo pipefail

# ================== Configuration ==================
# Backup source directory (will prompt for input by default, or pass as argument)
BACKUP_ROOT="/home/eai/doh/backups"

# Force overwrite existing containers/volumes during restore (default: ask)
FORCE_OVERWRITE=${FORCE_OVERWRITE:-false}

# MySQL root password for DB restore (will prompt when needed, or set via env var)
# export MYSQL_ROOT_PASSWORD=your_password_here   # Recommended to avoid prompting

# =============================================

DATE=$(date +"%Y%m%d_%H%M%S")
RESTORE_DIR=""
LOG_FILE=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

select_backup() {
    echo "=== Available Backup Directories ==="
    ls -1d "$BACKUP_ROOT"/20*_*/ 2>/dev/null | sort -r | nl -w2 -s') '
    
    if [ $? -ne 0 ] || [ -z "$(ls -A "$BACKUP_ROOT"/20*_*/ 2>/dev/null)" ]; then
        echo "Error: No backup directories found! Please ensure there are backup folders under $BACKUP_ROOT."
        exit 1
    fi
    
    echo
    read -p "Please select the backup number to restore (or enter full path directly): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && ls -d "$BACKUP_ROOT"/20*_*/ 1>/dev/null 2>&1; then
        RESTORE_DIR=$(ls -d "$BACKUP_ROOT"/20*_*/ | sort -r | sed -n "${choice}"p)
    else
        RESTORE_DIR="$choice"
    fi
    
    RESTORE_DIR="${RESTORE_DIR%/}"
    if [ ! -d "$RESTORE_DIR" ]; then
        echo "Error: Backup directory does not exist: $RESTORE_DIR"
        exit 1
    fi
    
    LOG_FILE="$RESTORE_DIR/restore_${DATE}.log"
    echo "Selected backup directory: $RESTORE_DIR" | tee "$LOG_FILE"
}

ask_force() {
    if [ "$FORCE_OVERWRITE" != "true" ]; then
        read -p "Force overwrite existing containers and volumes? (y/N): " ans
        [[ "$ans" =~ ^[yY]$ ]] && FORCE_OVERWRITE=true || FORCE_OVERWRITE=false
    fi
}

# =============== Restore Docker Images ===============
restore_docker_images() {
    local tarball="$RESTORE_DIR/docker_images.tar.gz"
    if [ ! -f "$tarball" ]; then
        log "Skipping image restore (docker_images.tar.gz not found)"
        return 0
    fi
    
    log "=== Restoring Docker Images and Restarting Services ==="
    local tmpdir=$(mktemp -d)
    tar -xzf "$tarball" -C "$tmpdir"
    
    for f in "$tmpdir"/*.tar; do
        [ -f "$f" ] || continue
        log "Loading $(basename "$f")"
        docker load -i "$f" | tee -a "$LOG_FILE"
    done
    
    # Change this path to where your actual docker-compose.yml is located
    local COMPOSE_FILE="/home/eai/doh/docker-compose.deploy.yml"
    
    if [ -f "$COMPOSE_FILE" ]; then
        log "Running docker-compose to rebuild and restart all containers..."
        (
            docker compose -f $COMPOSE_FILE down --remove-orphans || true
            docker compose -f $COMPOSE_FILE up -d --force-recreate --remove-orphans
        )
        log "All services have been restarted successfully!"
    else
        log "docker-compose.deploy.yml not found. Images loaded, but containers need manual restart."
    fi
    
    rm -rf "$tmpdir"
}

# =============== Restore Docker Volumes & Bind Mounts (Advanced) ===============
restore_docker_volumes() {
    local tarball="$RESTORE_DIR/docker_volumes.tar.gz"
    if [ ! -f "$tarball" ]; then
        log "Skipping volume/bind mount restore (docker_volumes.tar.gz not found)"
        return 0
    fi
    
    log "=== Starting Restore of Docker Volumes and Bind Mounts (supports multiple bind paths) ==="
    local tmpdir=$(mktemp -d)
    tar -xzf "$tarball" -C "$tmpdir"
    
    # Your project root directory (adjust according to your setup)
    local PROJECT_ROOT="/home/eai/doh"   # ← Change to your docker-compose project root
    
    for gzfile in "$tmpdir"/*.tar.gz; do
        [ -f "$gzfile" ] || continue
        
        local basename=$(basename "$gzfile" .tar.gz)
        local container_name="${basename%%__*}"
        local rest="${basename#*__}"
        local dest_path=$(echo "$rest" | rev | cut -d'_' -f2- | rev | tr '_' '/')
        local type=$(echo "$rest" | rev | cut -d'_' -f1 | rev)   # volume or bind
        log "Restoring $type → $container_name: $dest_path"
        
        if [ "$type" = "volume" ]; then
            # Volume handling (auto-detect name + force clear & restore)
            local volume_name=$(echo "$dest_path" | sed 's|/|_|g' | sed 's|^_*||')
            volume_name="doh_${volume_name}"  # Your volume naming convention
            
            docker volume inspect "$volume_name" >/dev/null 2>&1 || docker volume create "$volume_name" >/dev/null
            
            if [ "$FORCE_OVERWRITE" = true ] || read -t 20 -p "Clear and restore volume $volume_name? (y/N): " ans && [[ "$ans" =~ ^[yY]$ ]]; then
                log "  Restoring volume $volume_name ..."
                docker run --rm -v "$volume_name":/data -v "$gzfile":/backup.tar.gz alpine \
                sh -c "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true; tar xzf /backup.tar.gz -C /data"
                log "  Volume $volume_name restored successfully"
            else
                log "  Skipped volume $volume_name"
            fi
            
        else  # bind mount
            local target_host_path=""
            
            # Match your actual bind mount rules
            case "$dest_path" in
                "app/STORAGE")
                    # Automatically determine UAT or PROD based on container name
                    # if [[ "$container_name" == *"uat"* ]] || [[ "$container_name" == *"UAT"* ]]; then
                        target_host_path="/data/App_STOR"
                    # else
                        # target_host_path="/data/App_STOR/prod"
                    # fi
                ;;
                
                "app/public/email-templates/custom")
                    # if [[ "$container_name" == *"uat"* ]] || [[ "$container_name" == *"UAT"* ]]; then
                    target_host_path="$PROJECT_ROOT/app/email-templates"
                    # else
                    # target_host_path="$PROJECT_ROOT/app/email-templates/prod"
                    # fi
                ;;
                
                *)
                    # Generic fallback for other bind mounts
                    local relative=$(echo "$dest_path" | sed 's|^/app/||')
                    if [[ "$container_name" == *"uat"* ]]; then
                        target_host_path="$PROJECT_ROOT/$relative/uat"
                    elif [[ "$container_name" == *"prod"* ]]; then
                        target_host_path="$PROJECT_ROOT/$relative/prod"
                    else
                        target_host_path="$PROJECT_ROOT/$relative"
                    fi
                ;;
            esac
            echo "Target HOST path: $target_host_path"
            mkdir -p "$target_host_path"
            
            if [ "$FORCE_OVERWRITE" = true ] || read -t 20 -p "Overwrite host directory $target_host_path? (y/N): " ans && [[ "$ans" =~ ^[yY]$ ]]; then
                log "  Restoring bind mount → $target_host_path"
                tar -xzf "$gzfile" -C "$target_host_path" --overwrite
                log "  Bind mount restored: $target_host_path"
            else
                log "  Skipped bind mount $target_host_path"
            fi
        fi
    done
    
    rm -rf "$tmpdir"
    log "=== All Volumes and Bind Mounts Restored Successfully ==="
}

# =============== Restore Databases ===============
restore_database() {
    local tarball="$RESTORE_DIR/databases.tar.gz"
    if [ ! -f "$tarball" ]; then
        log "Warning: databases.tar.gz not found, skipping database restore"
        return 0
    fi
    
    log "=== Starting Database Restore ==="
    
    local tmpdir=$(mktemp -d)
    tar -xzf "$tarball" -C "$tmpdir"
    
    for sqlfile in "$tmpdir"/*.sql; do
        [ -f "$sqlfile" ] || continue
        local container_name=$(basename "$sqlfile" .sql)
        [ -z "${MYSQL_ROOT_PASSWORD:-}" ] && read -sp "Please enter MySQL root password: " MYSQL_ROOT_PASSWORD && echo
        
        if ! docker ps --format "{{.Names}}" | grep -qw "^${container_name}$"; then
            log "Warning: Container $container_name is not running, attempting to start or skip"
            read -p "Start container $container_name? (y/N): " ans
            if [[ "$ans" =~ ^[yY]$ ]]; then
                docker start "$container_name" || {
                    log "Error: Failed to start container $container_name"
                    continue
                }
                sleep 10
            else
                continue
            fi
        fi
        
        log "Restoring database to container $container_name ..."
        if docker exec -i "$container_name" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "$sqlfile"; then
            log "Success: Database restored successfully for $container_name"
        else
            log "Error: Database restore failed for $container_name!"
        fi
    done
    
    rm -rf "$tmpdir"
    log "=== Database Restore Completed ==="
}

# =============== Main Process ===============
main() {
    echo "========== Docker Backup Restore Tool =========="
    
    # Select restore directory
    if [ $# -ge 1 ] && [ -d "$1" ]; then
        RESTORE_DIR="$1"
        LOG_FILE="$RESTORE_DIR/restore_${DATE}.log"
    else
        select_backup
    fi
    
    log "Restore started from directory: $RESTORE_DIR"
    ask_force
    
    # Show detected restore items
    echo
    echo "Detected the following restorable items:"
    echo "-------------------------------------------"
    [ -f "$RESTORE_DIR/docker_images.tar.gz" ] && echo "  1. [Images]   docker_images.tar.gz"
    [ -f "$RESTORE_DIR/docker_volumes.tar.gz" ] && echo "  2. [Volumes]  docker_volumes.tar.gz"
    [ -f "$RESTORE_DIR/databases.tar.gz" ] && echo "  3. [Database] databases.tar.gz"
    
    if ! ls "$RESTORE_DIR"/*.tar.gz >/dev/null 2>&1; then
        echo "Error: No .tar.gz backup files found in $RESTORE_DIR!"
        exit 1
    fi
    
    echo "-------------------------------------------"
    echo "You can enter numbers to select items to restore (supports multiple, ranges, or all)"
    echo "Examples:"
    echo "   1             → Restore only Images"
    echo "   1 3           → Restore Images and Database"
    echo "   1-3           → Restore all"
    echo "   all           → Restore all"
    echo
    
    read -p "Select items to restore [default: all]: " choice
    choice=${choice:-all}
    
    # Parse user selection
    DO_IMAGES=false
    DO_VOLUMES=false
    DO_DATABASE=false
    
    if [[ "$choice" == "all" || "$choice" == "1-3" ]]; then
        [ -f "$RESTORE_DIR/docker_images.tar.gz" ]   && DO_IMAGES=true
        [ -f "$RESTORE_DIR/docker_volumes.tar.gz" ]  && DO_VOLUMES=true
        [ -f "$RESTORE_DIR/databases.tar.gz" ]       && DO_DATABASE=true
    else
        for part in $choice; do
            if [[ "$part" == *-* ]]; then
                start=${part%-*}
                end=${part#*-}
                for ((i=start; i<=end; i++)); do
                    case $i in
                        1) [ -f "$RESTORE_DIR/docker_images.tar.gz" ] && DO_IMAGES=true ;;
                        2) [ -f "$RESTORE_DIR/docker_volumes.tar.gz" ] && DO_VOLUMES=true ;;
                        3) [ -f "$RESTORE_DIR/databases.tar.gz" ] && DO_DATABASE=true ;;
                    esac
                done
            else
                case "$part" in
                    1) [ -f "$RESTORE_DIR/docker_images.tar.gz" ] && DO_IMAGES=true ;;
                    2) [ -f "$RESTORE_DIR/docker_volumes.tar.gz" ] && DO_VOLUMES=true ;;
                    3) [ -f "$RESTORE_DIR/databases.tar.gz" ] && DO_DATABASE=true ;;
                esac
            fi
        done
    fi
    
    # Show what will be restored
    echo
    echo "The following items will be restored:"
    $DO_IMAGES   && echo "  [Images]   docker_images.tar.gz"
    $DO_VOLUMES  && echo "  [Volumes]  docker_volumes.tar.gz"
    $DO_DATABASE && echo "  [Database] databases.tar.gz"
    
    if ! $DO_IMAGES && ! $DO_VOLUMES && ! $DO_DATABASE; then
        echo "No items selected!"
        exit 0
    fi
    
    read -p "Confirm start restore? (y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { echo "Restore cancelled"; exit 0; }
    
    # Execute selected restore functions
    $DO_IMAGES   && restore_docker_images
    $DO_VOLUMES  && restore_docker_volumes
    $DO_DATABASE && restore_database
    
    log "============================================"
    log "All restore operations completed successfully!"
    log "Restore directory: $RESTORE_DIR"
    log "Log file: $LOG_FILE"
    echo
    echo "Restore completed! Log saved to: $LOG_FILE"
}

main "$@"