#!/bin/bash
# Game Save Backup Script
#
# Backs up game saves from VMs to NAS storage with versioning.
# Supports Steam cloud saves, RetroArch saves, and custom game directories.
#
# Usage:
#   backup-saves.sh [--user USER] [--game GAME] [--all] [--restore SNAPSHOT]
#
# Environment:
#   GAMING_NFS_MOUNT - NFS mount point (default: /mnt/gaming)
#   BACKUP_RETENTION - Number of backups to keep per game (default: 10)

set -euo pipefail

# Configuration
NFS_MOUNT="${GAMING_NFS_MOUNT:-/mnt/gaming}"
BACKUP_DIR="${NFS_MOUNT}/backups"
SAVES_DIR="${NFS_MOUNT}/cloud-saves"
RETENTION="${BACKUP_RETENTION:-10}"

# Save locations
declare -A SAVE_PATHS=(
    # Steam saves (common locations)
    ["steam-linux"]="$HOME/.local/share/Steam/userdata"
    ["steam-windows"]="$HOME/drive_c/Program Files (x86)/Steam/userdata"

    # RetroArch saves
    ["retroarch"]="$HOME/.config/retroarch/saves"
    ["retroarch-states"]="$HOME/.config/retroarch/states"

    # Proton prefixes (game-specific)
    ["proton"]="$HOME/.local/share/Steam/steamapps/compatdata"

    # GOG saves
    ["gog"]="$HOME/GOG Games"

    # Heroic (Epic/GOG launcher)
    ["heroic"]="$HOME/.config/heroic/gog_store"
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Ensure backup directory exists
ensure_backup_dir() {
    local user="$1"
    local game="$2"
    local dir="${BACKUP_DIR}/${user}/${game}"
    mkdir -p "$dir"
    echo "$dir"
}

# Create a timestamped backup
create_backup() {
    local source="$1"
    local dest_dir="$2"
    local name="$3"

    if [[ ! -d "$source" && ! -f "$source" ]]; then
        log "WARNING: Source does not exist: $source"
        return 1
    fi

    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_name="${name}_${timestamp}"
    local dest="${dest_dir}/${backup_name}"

    log "Creating backup: $source -> $dest"

    if [[ -d "$source" ]]; then
        # Directory backup
        tar -czf "${dest}.tar.gz" -C "$(dirname "$source")" "$(basename "$source")" 2>/dev/null
    else
        # Single file backup
        cp "$source" "${dest}"
    fi

    # Create symlink to latest
    ln -sf "$(basename "${dest}.tar.gz" 2>/dev/null || basename "$dest")" "${dest_dir}/latest"

    log "Backup created: ${backup_name}"
    return 0
}

# Enforce retention policy
cleanup_old_backups() {
    local backup_dir="$1"
    local keep="$2"

    # Get list of backups sorted by time (oldest first)
    local backups=()
    while IFS= read -r -d '' file; do
        backups+=("$file")
    done < <(find "$backup_dir" -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "*_[0-9]*" \) -print0 | sort -z)

    local count=${#backups[@]}
    local to_delete=$((count - keep))

    if [[ $to_delete -gt 0 ]]; then
        log "Cleaning up $to_delete old backups (keeping $keep)"
        for ((i=0; i<to_delete; i++)); do
            rm -f "${backups[$i]}"
            log "Deleted: ${backups[$i]}"
        done
    fi
}

# Restore from a backup
restore_backup() {
    local backup_file="$1"
    local restore_to="$2"

    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
    fi

    log "Restoring: $backup_file -> $restore_to"

    # Create backup of current state before restore
    if [[ -d "$restore_to" ]]; then
        local pre_restore_backup="${restore_to}.pre-restore.$(date '+%Y%m%d_%H%M%S')"
        mv "$restore_to" "$pre_restore_backup"
        log "Current state backed up to: $pre_restore_backup"
    fi

    mkdir -p "$(dirname "$restore_to")"

    if [[ "$backup_file" == *.tar.gz ]]; then
        tar -xzf "$backup_file" -C "$(dirname "$restore_to")"
    else
        cp "$backup_file" "$restore_to"
    fi

    log "Restore completed"
}

# Backup Steam saves for a user
backup_steam() {
    local user="$1"
    local steam_dir="${SAVE_PATHS[steam-linux]}"

    [[ -d "$steam_dir" ]] || return 0

    log "Backing up Steam saves for user: $user"

    # Each Steam user ID is a subdirectory
    for user_id in "$steam_dir"/*/; do
        [[ -d "$user_id" ]] || continue

        local id=$(basename "$user_id")
        local backup_dir=$(ensure_backup_dir "$user" "steam-${id}")

        create_backup "$user_id" "$backup_dir" "steam_${id}"
        cleanup_old_backups "$backup_dir" "$RETENTION"
    done
}

# Backup RetroArch saves
backup_retroarch() {
    local user="$1"

    for save_type in retroarch retroarch-states; do
        local source="${SAVE_PATHS[$save_type]}"
        [[ -d "$source" ]] || continue

        log "Backing up $save_type for user: $user"
        local backup_dir=$(ensure_backup_dir "$user" "$save_type")

        create_backup "$source" "$backup_dir" "$save_type"
        cleanup_old_backups "$backup_dir" "$RETENTION"
    done
}

# Backup Proton game saves
backup_proton() {
    local user="$1"
    local game_filter="${2:-}"  # Optional: specific AppID

    local proton_dir="${SAVE_PATHS[proton]}"
    [[ -d "$proton_dir" ]] || return 0

    log "Backing up Proton saves for user: $user"

    for app_dir in "$proton_dir"/*/; do
        [[ -d "$app_dir" ]] || continue

        local app_id=$(basename "$app_dir")

        # Skip if filtering for specific game
        if [[ -n "$game_filter" && "$app_id" != "$game_filter" ]]; then
            continue
        fi

        # Only backup if there's actual save data
        local save_dir="${app_dir}pfx/drive_c/users/steamuser"
        [[ -d "$save_dir" ]] || continue

        local backup_dir=$(ensure_backup_dir "$user" "proton-${app_id}")

        # Backup the entire prefix save area
        create_backup "$save_dir" "$backup_dir" "proton_${app_id}"
        cleanup_old_backups "$backup_dir" "$RETENTION"
    done
}

# List available backups
list_backups() {
    local user="${1:-}"
    local game="${2:-}"

    local search_dir="$BACKUP_DIR"
    [[ -n "$user" ]] && search_dir="${search_dir}/${user}"
    [[ -n "$game" ]] && search_dir="${search_dir}/${game}"

    if [[ ! -d "$search_dir" ]]; then
        log "No backups found in: $search_dir"
        return 0
    fi

    log "Available backups in: $search_dir"
    find "$search_dir" -type f \( -name "*.tar.gz" -o -name "*_[0-9]*" \) | sort | while read -r file; do
        local size=$(du -h "$file" 2>/dev/null | cut -f1)
        local date=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1)
        echo "  $date  $size  $(basename "$file")"
    done
}

# Main backup routine for a user
backup_all() {
    local user="$1"

    log "=== Starting full backup for user: $user ==="

    backup_steam "$user"
    backup_retroarch "$user"
    backup_proton "$user"

    log "=== Backup complete for user: $user ==="
}

# Usage help
show_help() {
    cat <<EOF
Game Save Backup Utility

Usage:
  $0 [options]

Options:
  --user USER       Specify user name (default: current user)
  --game GAME       Backup specific game/type (steam, retroarch, proton-APPID)
  --all             Backup all save types
  --list            List available backups
  --restore FILE    Restore from a backup file
  --to PATH         Destination path for restore
  --retention N     Number of backups to keep (default: $RETENTION)
  --help            Show this help

Examples:
  $0 --all                           # Backup all saves for current user
  $0 --user alice --game retroarch   # Backup RetroArch saves for alice
  $0 --list --user bob               # List bob's backups
  $0 --restore /path/to/backup.tar.gz --to ~/.config/retroarch/saves

EOF
}

# Parse arguments
USER_NAME="${USER:-$(whoami)}"
GAME=""
DO_ALL=false
DO_LIST=false
RESTORE_FILE=""
RESTORE_TO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            USER_NAME="$2"
            shift 2
            ;;
        --game)
            GAME="$2"
            shift 2
            ;;
        --all)
            DO_ALL=true
            shift
            ;;
        --list)
            DO_LIST=true
            shift
            ;;
        --restore)
            RESTORE_FILE="$2"
            shift 2
            ;;
        --to)
            RESTORE_TO="$2"
            shift 2
            ;;
        --retention)
            RETENTION="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Execute requested action
if [[ -n "$RESTORE_FILE" ]]; then
    [[ -z "$RESTORE_TO" ]] && error "Must specify --to PATH for restore"
    restore_backup "$RESTORE_FILE" "$RESTORE_TO"
elif $DO_LIST; then
    list_backups "$USER_NAME" "$GAME"
elif $DO_ALL; then
    backup_all "$USER_NAME"
elif [[ -n "$GAME" ]]; then
    case "$GAME" in
        steam)
            backup_steam "$USER_NAME"
            ;;
        retroarch)
            backup_retroarch "$USER_NAME"
            ;;
        proton-*)
            app_id="${GAME#proton-}"
            backup_proton "$USER_NAME" "$app_id"
            ;;
        *)
            error "Unknown game type: $GAME. Use: steam, retroarch, proton-APPID"
            ;;
    esac
else
    show_help
    exit 1
fi
