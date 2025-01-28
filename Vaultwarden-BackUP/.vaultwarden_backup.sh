#!/bin/bash

if [ "$(docker container inspect -f '{{.State.Status}}' vaultwarden)" != "exited" ]; then
    exit 0
fi

# Variables
BACKUP_DIR="/vw-data-backups" # Backup directory where backups are stored
VW_DATA="/vw-data" # Directory to restore Vaultwarden data
BACKUP_RETAIN_DAYS=14 # Number of days to keep backups

# Clean up old Vaultwarden data
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Backup directory does not exist. Exiting..." 1>&2
    exit 1
fi
rm -rf "$VW_DATA/attachments" "$VW_DATA/sends" "$VW_DATA/icon_cache"
rm "$VW_DATA/config.json"
rm "$VW_DATA/rsa_key.pem"
rm "$VW_DATA/db.sqlite3"
rm "$VM_DATA/db.sqlite3-wal"

# Restore the latest Vaultwarden data
latest_backup=$(ls -t "$BACKUP_DIR" | head -n1)

cp -r "$BACKUP_DIR/$latest_backup/attachments" "$VW_DATA/"
cp -r "$BACKUP_DIR/$latest_backup/sends" "$VW_DATA/"
cp "$BACKUP_DIR/$latest_backup/config.json" "$VW_DATA/"
cp "$BACKUP_DIR/$latest_backup/rsa_key.pem" "$VW_DATA/"
cp -r "$BACKUP_DIR/$latest_backup/icon_cache" "$VW_DATA/"
cp "$BACKUP_DIR/$latest_backup/db.sqlite3" "$VW_DATA/"

# Clean up old backups
find "$BACKUP_DIR" -type d -mtime +$BACKUP_RETAIN_DAYS -exec rm -rf {} \;