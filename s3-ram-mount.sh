#!/bin/bash

# Detect the real user even if the script is run with sudo
ACTUAL_USER=${SUDO_USER:-$USER}
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

# Configuration
S3_BUCKET="benjiworld"
ENDPOINT="https://eu-west-1.s3.fil.one"
REGION="eu-west-1"

# Directories are now strictly forced into the real user's home folder
S3_MOUNTPOINT="$ACTUAL_HOME/FiloneRAM"
RAM_DISK="$ACTUAL_HOME/.Filone_RAM_Cache" # Hidden directory for cache

echo "🚀 Preparing S3 RAM-backed environment for user: $ACTUAL_USER..."

# 1. Cleanup function for graceful exit
cleanup() {
    echo -e "\n🛑 Caught CTRL+C! Cleaning up and shutting down..."
    
    # Unmount directories
    for DIR in "$S3_MOUNTPOINT" "$RAM_DISK"; do
        if mountpoint -q "$DIR" 2>/dev/null; then
            echo "🧹 Unmounting $DIR..."
            sudo fusermount -u "$DIR" 2>/dev/null
            sudo umount "$DIR" 2>/dev/null
            sleep 1
        fi
    done

    # Delete the directories safely
    echo "🗑️ Deleting directories..."
    sudo rm -rf "$S3_MOUNTPOINT" "$RAM_DISK"
    
    echo "✅ Cleanup complete. Goodbye!"
    exit 0
}

# Trap the SIGINT (CTRL+C) and SIGTERM signals to trigger cleanup
trap cleanup SIGINT SIGTERM

# 2. Prepare directories as the real user
sudo -u "$ACTUAL_USER" mkdir -p "$RAM_DISK" "$S3_MOUNTPOINT"

USER_UID=$(id -u "$ACTUAL_USER")
USER_GID=$(id -g "$ACTUAL_USER")

# 3. Create the RAM Disk
echo "🧠 Allocating 80% of available RAM for the cache disk..."
sudo mount -t tmpfs -o size=80%,uid=$USER_UID,gid=$USER_GID,mode=0755 tmpfs "$RAM_DISK"

if ! mountpoint -q "$RAM_DISK"; then
    echo "❌ Failed to create RAM disk."
    exit 1
fi

# 4. Mount the S3 bucket AS THE REAL USER (forces it to find your .aws/credentials)
echo "☁️  Mounting $S3_BUCKET from Fil.one..."
sudo -u "$ACTUAL_USER" mount-s3 "$S3_BUCKET" "$S3_MOUNTPOINT" \
  --endpoint-url "$ENDPOINT" \
  --region "$REGION" \
  --profile default \
  --force-path-style \
  --allow-delete \
  --allow-overwrite \
  --allow-other \
  --cache "$RAM_DISK" \
  --metadata-ttl 60

# 5. Verify S3 Mount
sleep 2
if mountpoint -q "$S3_MOUNTPOINT"; then
    echo "-------------------------------------------------------"
    echo "✅ SUCCESS! S3 environment is live."
    echo "📁 Your Files: $S3_MOUNTPOINT"
    echo "💨 RAM Cache:  $RAM_DISK (Hidden)"
    echo "⚠️  Press CTRL+C at any time to unmount and delete folders."
    echo "-------------------------------------------------------"
else
    echo "❌ Mountpoint failed to connect to S3. Check your credentials."
    cleanup
fi

# 6. Keep the script alive in the background waiting for CTRL+C
while true; do
    sleep 1
done
