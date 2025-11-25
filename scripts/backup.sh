#!/bin/bash

set -euo pipefail  # Stricter error handling

DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/home/eai/doh/backups/${DATE}"
USER_DATA="/data/App_STOR"
BACKUP_USER_DATA_DIR="${BACKUP_DIR}${USER_DATA}"
LOG_FILE="${BACKUP_DIR}/backup_${DATE}.log"

mkdir -p "$BACKUP_DIR"

# Function to write logs
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Backup running specified Docker images
backup_docker_images() {
    local BACKUP_DOCKER_IMAGES_DIR="${BACKUP_DIR}/docker_images"
    mkdir -p "$BACKUP_DOCKER_IMAGES_DIR"
    
    log "=== Docker Images backup started ==="
    
    # Only backup images used by running containers that contain "dashboard" or "web-service"
    IMAGES=$(docker ps --format "{{.Image}}" | sort -u | grep -E "(dashboard|web-service)")
    
    if [ -z "$IMAGES" ]; then
        log "Warning: No running containers matching the criteria (dashboard or web-service) found, skipping image backup."
        return 0
    fi
    
    log "Found the following running images: $IMAGES"
    
    for IMAGE in $IMAGES; do
        SAFE_NAME=$(echo "$IMAGE" | sed 's/[\/:]/_/g')
        OUTPUT_FILE="${BACKUP_DOCKER_IMAGES_DIR}/${SAFE_NAME}.tar"
        
        log "Saving image: $IMAGE → ${OUTPUT_FILE}"
        if docker save "$IMAGE" -o "$OUTPUT_FILE"; then
            log "Successfully saved $IMAGE"
        else
            log "Error: Failed to backup $IMAGE!"
        fi
    done
    
    log "Compressing to $BACKUP_DIR/docker_images.tar.gz"
    tar -czf "$BACKUP_DIR/docker_images.tar.gz" -C $BACKUP_DOCKER_IMAGES_DIR .
    rm -rf $BACKUP_DOCKER_IMAGES_DIR
    
    log "=== Docker Images backup completed ==="
}

# Backup all mounted volumes (volumes and bind mounts) of running containers
backup_docker_volumes() {
    local BACKUP_DOCKER_VOLUMES_DIR="${BACKUP_DIR}/docker_volumes"
    mkdir -p "$BACKUP_DOCKER_VOLUMES_DIR"
    
    log "=== Docker Volumes / Bind Mounts backup started ==="
    CONTAINERS=$(docker ps --format "{{.ID}}\t{{.Names}}\t{{.Image}}" | grep -E "(web-service)" | awk '{print $1}')
    
    if [ -z "$CONTAINERS" ]; then
        log "Warning: No running web-service container found, skipping volume backup."
        return 0
    fi
    
    log "Found the following containers to backup their mounts:"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}" | grep -E "(web-service)" | tee -a "$LOG_FILE"
    
    for CID in $CONTAINERS; do
        CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$CID" | sed 's/^\///')
        log "Processing container: $CONTAINER_NAME ($CID)"
        
        docker inspect "$CID" | jq -r '.[0].Mounts[]? | "\(.Type)\t\(.Source)\t\(.Destination)"' | while IFS=$'\t' read -r type source dest; do
            if [ -z "$source" ] || [ "$source" = "null" ]; then
                continue
            fi
            
            SAFE_DEST=$(echo "$dest" | sed 's|/|_|g' | sed 's|^_*||')
            TARGET_NAME="${CONTAINER_NAME}__${SAFE_DEST}_${type}"
            BACKUP_PATH="${BACKUP_DOCKER_VOLUMES_DIR}/${TARGET_NAME}"
            
            log "  Backing up mount: $source ($type) -> $dest"
            
            if [ "$type" = "volume" ]; then
                docker run --rm -v "$source":/data -v "$BACKUP_DOCKER_VOLUMES_DIR":/backup alpine \
                tar czf "/backup/${TARGET_NAME}.tar.gz" -C /data . || log "  Warning: Volume backup failed"
            else
                tar czf "${BACKUP_PATH}.tar.gz" -C "$(dirname "$source")" "$(basename "$source")" && \
                log "  Successfully backed up bind mount" || log "  Warning: Bind mount backup failed"
            fi
        done
    done
    
    log "Compressing to $BACKUP_DIR/docker_volumes.tar.gz"
    tar -czf "$BACKUP_DIR/docker_volumes.tar.gz" -C $BACKUP_DOCKER_VOLUMES_DIR .
    rm -rf $BACKUP_DOCKER_VOLUMES_DIR
    
    log "=== Docker Volumes / Bind Mounts backup completed ==="
}

backup_database() {
    local BACKUP_DATABASE_DIR="${BACKUP_DIR}/database"
    mkdir -p "$BACKUP_DATABASE_DIR"
    
    CONTAINERS=$(docker ps --format "{{.ID}}\t{{.Names}}\t{{.Image}}" | grep -E "(mysql)" | awk '{print $1}')
    
    if [ -z "$CONTAINERS" ]; then
        log "Warning: No running db container found, skipping database backup."
        return 0
    fi
    
    log "Found the following running databases:"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}" | grep -E "(mysql)" | tee -a "$LOG_FILE"
    
    for CID in $CONTAINERS; do
        CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$CID" | sed 's/^\///')
        log "Processing database: $CONTAINER_NAME ($CID)"
        
        docker exec $CID sh -c \
        'exec mysqldump --all-databases -uroot -p"$MYSQL_ROOT_PASSWORD" \
        --single-transaction --quick --lock-tables=false' \
        > "$BACKUP_DATABASE_DIR/${CONTAINER_NAME}.sql"
    done
    
    log "Compressing to $BACKUP_DATABASE_DIR/databases.tar.gz"
    tar -czf "$BACKUP_DIR/databases.tar.gz" -C $BACKUP_DATABASE_DIR .
    rm -rf $BACKUP_DATABASE_DIR
    
    log "=== Database backup completed ==="
}

# Main function
main() {
    log "Backup started, directory: $BACKUP_DIR"
    
    backup_docker_images
    backup_docker_volumes
    backup_database
    
    log "All backups completed! Backup location: $BACKUP_DIR"
    echo "Backup completed! Location: $BACKUP_DIR"
}

# Execute
main