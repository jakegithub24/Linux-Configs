#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (can be overridden by user input) ---
IMAGE_DIR="$HOME/Downloads/DietPi"
IMAGE_FILE="DietPi_NativePC-UEFI-x86_64-Bookworm.img.xz"
CHECKSUM_FILE="${IMAGE_FILE}.sha256"

# --- Helper functions ---
die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# --- 0. Ensure we are in the image directory and files exist ---
cd "$IMAGE_DIR" || die "Image directory $IMAGE_DIR not found."
[[ -f "$IMAGE_FILE" ]] || die "$IMAGE_FILE not found. Please download it first."
[[ -f "$CHECKSUM_FILE" ]] || die "$CHECKSUM_FILE not found. Please download it first."

echo "Verifying image checksum..."
sha256sum -c "$CHECKSUM_FILE" || die "Checksum mismatch. Re-download the image."

# --- 1. Select target USB device ---
echo
echo "Available block devices:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,TRAN | awk 'NR==1 || /disk/' || true
echo

read -rp "Enter the target USB device (e.g., sdc, WITHOUT /dev/): " TARGET_DEV
[[ -z "$TARGET_DEV" ]] && die "No device entered."
TARGET_DEV="/dev/$TARGET_DEV"
[[ -b "$TARGET_DEV" ]] || die "$TARGET_DEV is not a valid block device."

# Safety check: not the root device
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
if [[ "$TARGET_DEV" == "$ROOT_DEV" ]]; then
    die "Refusing to overwrite the root device!"
fi

# Confirm
echo
echo "!!! WARNING: This will DESTROY ALL DATA on $TARGET_DEV !!!"
read -rp "Type 'YES' to proceed: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && die "Aborted."

# --- 2. Unmount any mounted partitions of the target device ---
echo "Unmounting any partitions on $TARGET_DEV..."
sudo umount "${TARGET_DEV}"* 2>/dev/null || true

# --- 3. Write the image with dd ---
echo "Writing $IMAGE_FILE to $TARGET_DEV (this may take a few minutes)..."
sudo dd if="$IMAGE_FILE" of="$TARGET_DEV" bs=4M status=progress conv=fsync

echo "Syncing..."
sync

# --- 4. Reload partition table ---
echo "Reloading partition table..."
if sudo partprobe "$TARGET_DEV"; then
    echo "Partition table reloaded successfully."
else
    warn "partprobe failed (likely still in use)."
    echo "Please physically unplug the USB drive, wait 2 seconds, and plug it back in."
    echo "Then press Enter to continue."
    read -r
fi

# --- 5. Mount the boot partition and pre-configure ---
BOOT_PART="${TARGET_DEV}1"
MOUNT_POINT="/mnt/dietpi_boot"

echo "Waiting for $BOOT_PART to appear..."
for i in {1..10}; do
    if [[ -b "$BOOT_PART" ]]; then break; fi
    sleep 1
done
[[ -b "$BOOT_PART" ]] || die "$BOOT_PART not found. Cannot proceed."

echo "Mounting $BOOT_PART to $MOUNT_POINT..."
sudo mkdir -p "$MOUNT_POINT"
sudo mount "$BOOT_PART" "$MOUNT_POINT" || die "Failed to mount boot partition."

CONFIG_FILE="$MOUNT_POINT/dietpi.txt"
[[ -f "$CONFIG_FILE" ]] || die "dietpi.txt not found on boot partition. Is this a valid DietPi image?"

echo
echo "Enter the headless configuration:"

# Collect user input
read -rp "Static IP address (e.g., 192.168.0.100): " STATIC_IP
read -rp "Netmask (e.g., 255.255.255.0): " NETMASK
read -rp "Gateway (e.g., 192.168.0.1): " GATEWAY
read -rp "DNS server (e.g., 8.8.8.8): " DNS
read -rp "Password for root/dietpi users: " PASSWORD

echo "Applying configuration to $CONFIG_FILE..."

# Use sudo to edit. We'll create a backup first.
sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

sudo sed -i \
    -e "s/^[[:space:]]*AUTO_SETUP_AUTOMATED=.*/AUTO_SETUP_AUTOMATED=1/" \
    -e "s/^[[:space:]]*AUTO_SETUP_HEADLESS=.*/AUTO_SETUP_HEADLESS=1/" \
    -e "s/^[[:space:]]*AUTO_SETUP_NET_USESTATIC=.*/AUTO_SETUP_NET_USESTATIC=1/" \
    -e "s/^[[:space:]]*AUTO_SETUP_NET_STATIC_IP=.*/AUTO_SETUP_NET_STATIC_IP=$STATIC_IP/" \
    -e "s/^[[:space:]]*AUTO_SETUP_NET_STATIC_MASK=.*/AUTO_SETUP_NET_STATIC_MASK=$NETMASK/" \
    -e "s/^[[:space:]]*AUTO_SETUP_NET_STATIC_GATEWAY=.*/AUTO_SETUP_NET_STATIC_GATEWAY=$GATEWAY/" \
    -e "s/^[[:space:]]*AUTO_SETUP_NET_STATIC_DNS=.*/AUTO_SETUP_NET_STATIC_DNS=$DNS/" \
    -e "s/^[[:space:]]*AUTO_SETUP_GLOBAL_PASSWORD=.*/AUTO_SETUP_GLOBAL_PASSWORD=$PASSWORD/" \
    -e "s/^[[:space:]]*CONFIG_BOOT_WAIT_FOR_NETWORK=.*/CONFIG_BOOT_WAIT_FOR_NETWORK=2/" \
    "$CONFIG_FILE"

# Verify changes
echo "------"
echo "New settings:"
grep -E "^[[:space:]]*(AUTO_SETUP_AUTOMATED|AUTO_SETUP_HEADLESS|AUTO_SETUP_NET_|AUTO_SETUP_GLOBAL_PASSWORD|CONFIG_BOOT_WAIT_FOR_NETWORK)" "$CONFIG_FILE"
echo "------"

# --- 6. Clean up ---
sudo umount "$MOUNT_POINT"
sudo rmdir "$MOUNT_POINT" 2>/dev/null || true

echo
echo "------------------------------------------------------"
echo "Success! Your DietPi USB drive is ready."
echo "1. Remove the drive and plug it into your headless laptop."
echo "2. Boot from USB (you may need to enter BIOS/UEFI)."
echo "3. After a few minutes, connect via SSH:"
echo "   ssh root@$STATIC_IP"
echo "   Password: $PASSWORD"
echo "------------------------------------------------------"
