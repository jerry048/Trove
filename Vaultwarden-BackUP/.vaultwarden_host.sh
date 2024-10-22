#!/bin/bash

# Variables
remote="remote" # Remote destination for rclone
BACKUP_DIR="/vw-data-backups" # Backup directory for the sqlite dump
VW_DATA="/vw-data" # Vaultwarden data directory
DATE=$(date +"%Y%m%d")

# Ensure the backup directory exists
mkdir -p "$BACKUP_DIR"

# Step 1: Backup the database using sqlite3
sqlite3 $VW_DATA/db.sqlite3 ".backup '$BACKUP_DIR/db.sqlite3'"

# Step 2: Use rclone to copy the files to the remote server
rclone copy $VW_DATA/attachments "$remote:/vw-data-backups/$DATE/attachments"
rclone copy $VW_DATA/sends "$remote:/vw-data-backups/$DATE/sends"
rclone copy $VW_DATA/config.json "$remote:/vw-data-backups/$DATE/"
rclone copy $VW_DATA/rsa_key.pem "$remote:/vw-data-backups/$DATE/"
rclone copy $VW_DATA/icon_cache "$remote:/vw-data-backups/$DATE/icon_cache"
rclone move $BACKUP_DIR/db.sqlite3 "$remote:/vw-data-backups/$DATE/"