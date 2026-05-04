#!/usr/bin/env bash
set -euo pipefail

# -------------------- CONFIGURATION --------------------
# You can change these defaults or answer the prompts.
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.raw"
IMAGE_FILE="debian-12-genericcloud-amd64.raw"
DEFAULT_DEVICE="sdc"
DEFAULT_IP="192.168.0.100"
DEFAULT_NETMASK="255.255.255.0"
DEFAULT_GATEWAY="192.168.0.1"
DEFAULT_DNS="8.8.8.8"
DEFAULT_USER="devops"
DEFAULT_HOSTNAME="devops-server"
# ------------------------------------------------------

# Helper to print errors and exit
die() { echo "ERROR: $*" >&2; exit 1; }

# Check if running as root (or use sudo for commands that need it)
REQUIRED_CMDS=(dd parted mkfs.vfat mount lsblk curl sha512sum sync)
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

echo "=== Debian 12 Headless Server USB Creator ==="
echo

# 1. Download the cloud image if not present
if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "Downloading Debian cloud image..."
    curl -L -o "$IMAGE_FILE" "$IMAGE_URL" || die "Download failed"
    # Optionally verify checksum (we'll skip a full verification but at least check size)
fi

# Quick sanity check: the file should be at least 300 MB (314572800 bytes)
FILESIZE=$(stat -c%s "$IMAGE_FILE" 2>/dev/null || du -b "$IMAGE_FILE" | cut -f1)
if (( FILESIZE < 300000000 )); then
    die "Downloaded file is too small ($FILESIZE bytes). The download may have failed or the URL is wrong. Remove the file and try again."
fi

echo "Image file '$IMAGE_FILE' is present ($(( FILESIZE / 1048576 )) MB)."
echo

# 2. Select target device
echo "Available disks (lsblk output):"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,TRAN | grep -E "disk|NAME" | grep -v 'zram'
echo
read -rp "Enter the target USB device (e.g., $DEFAULT_DEVICE, without /dev/): " TARGET
TARGET=${TARGET:-$DEFAULT_DEVICE}
DEVICE="/dev/$TARGET"
[[ -b "$DEVICE" ]] || die "$DEVICE is not a valid block device."

# Safety: refuse to write to the root device
ROOT_DEVICE=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
if [[ "$DEVICE" == "$ROOT_DEVICE" ]]; then
    die "Refusing to overwrite the root device ($ROOT_DEVICE)."
fi

echo
echo "WARNING: All data on $DEVICE will be DESTROYED."
read -rp "Type 'YES' to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && die "Aborted."

# 3. Write the image to the USB drive
echo "Writing image to $DEVICE (this may take a few minutes)..."
dd if="$IMAGE_FILE" of="$DEVICE" bs=4M status=progress conv=fsync || die "dd failed"
sync
echo "Done writing."

# Re-read partition table
partprobe "$DEVICE" || true
sleep 2

# Check partition layout (should show at least two partitions)
echo "Partition table on $DEVICE:"
lsblk "$DEVICE"
echo

# Determine root partition and EFI partition automatically
# The cloud image has:
#  partition 1: EFI (vfat, label "EFI")
#  partition 2: root (ext4, label "root" or "cloudimg-rootfs")
ROOT_PART=""
EFI_PART=""
for p in "${DEVICE}"[0-9]*; do
    echo "Checking $p..."
    LABEL=$(lsblk -no LABEL "$p" 2>/dev/null || true)
    FSTYPE=$(lsblk -no FSTYPE "$p" 2>/dev/null || true)
    echo "  Label: $LABEL, Fstype: $FSTYPE"
    if [[ "$FSTYPE" == "ext4" ]]; then
        ROOT_PART="$p"
    elif [[ "$FSTYPE" == "vfat" ]]; then
        EFI_PART="$p"
    fi
done

if [[ -z "$ROOT_PART" ]]; then
    # Fallback: assume sdc2 is root if there's a second partition
    if [[ -b "${DEVICE}2" ]]; then
        ROOT_PART="${DEVICE}2"
        EFI_PART="${DEVICE}1"
    else
        die "Cannot find root partition on $DEVICE."
    fi
fi

echo "Detected root partition: $ROOT_PART"
echo "Detected EFI partition: $EFI_PART"
echo

# 4. Resize root filesystem to fill available space (up to ~7.5G)
# Only if there's free space after root partition. cloud image is small.
echo "Resizing root filesystem to use all available space..."
# First, grow the partition if possible (we'll just grow filesystem in-place)
e2fsck -f "$ROOT_PART" || true
resize2fs "$ROOT_PART" || true
echo "Filesystem resize attempted (may already be at max size)."
echo

# 5. Create the cloud-init CIDATA partition in the free space
# Check if there's already a third partition; if so, warn and remove it.
if [[ -b "${DEVICE}3" ]]; then
    echo "Removing existing third partition ${DEVICE}3..."
    parted "$DEVICE" rm 3
    partprobe "$DEVICE"
    sleep 1
fi

# Create a new 10 MiB FAT32 partition at the end
echo "Creating CIDATA partition..."
parted "$DEVICE" mkpart primary fat32 100%FREE || die "Failed to create partition"
partprobe "$DEVICE"
sleep 1

# Identify the new partition (should be the last one)
CIDATA_PART=""
for p in "${DEVICE}"[0-9]*; do
    # The one that is not root or efi
    if [[ "$p" != "$ROOT_PART" && "$p" != "$EFI_PART" ]]; then
        CIDATA_PART="$p"
        break
    fi
done

if [[ -z "$CIDATA_PART" || ! -b "$CIDATA_PART" ]]; then
    die "Could not find the CIDATA partition after creation."
fi

echo "Formatting $CIDATA_PART as FAT32 with label CIDATA..."
mkfs.vfat -n CIDATA "$CIDATA_PART" || die "mkfs.vfat failed"
echo "Done."

# 6. Mount CIDATA and write cloud-init files
MOUNT_POINT="/mnt/cidata"
mkdir -p "$MOUNT_POINT"
mount "$CIDATA_PART" "$MOUNT_POINT" || die "Failed to mount $CIDATA_PART"

# Collect configuration from user
echo
echo "=== Network Configuration ==="
read -rp "Hostname (default: $DEFAULT_HOSTNAME): " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
read -rp "Username (default: $DEFAULT_USER): " USERNAME
USERNAME=${USERNAME:-$DEFAULT_USER}
read -rp "Password for $USERNAME (leave blank to set 'password'): " USERPASS
USERPASS=${USERPASS:-password}

echo "Do you want to use DHCP or static IP? (d/s)"
read -rp "[d] DHCP, [s] Static (default: static): " IPMODE
IPMODE=${IPMODE:-s}

if [[ "$IPMODE" == "d" ]]; then
    NETWORK_BLOCK="# Using DHCP - no static configuration"
else
    read -rp "Static IP (default: $DEFAULT_IP): " STATIC_IP
    STATIC_IP=${STATIC_IP:-$DEFAULT_IP}
    read -rp "Netmask (default: $DEFAULT_NETMASK): " NETMASK
    NETMASK=${NETMASK:-$DEFAULT_NETMASK}
    read -rp "Gateway (default: $DEFAULT_GATEWAY): " GATEWAY
    GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
    read -rp "DNS server (default: $DEFAULT_DNS): " DNS
    DNS=${DNS:-$DEFAULT_DNS}
fi

# Generate hashed password for cloud-config (requires mkpasswd, part of whois)
if command -v mkpasswd >/dev/null 2>&1; then
    HASHED_PASSWD=$(mkpasswd -m sha-512 "$USERPASS")
else
    # Fallback to a simple hash using openssl (less secure)
    HASHED_PASSWD=$(openssl passwd -6 "$USERPASS")
fi

# Write meta-data
cat > "$MOUNT_POINT/meta-data" <<EOF
instance-id: iid-server01
local-hostname: $HOSTNAME
EOF

# Write user-data
cat > "$MOUNT_POINT/user-data" <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true

users:
  - name: $USERNAME
    gecos: DevOps User
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: "$HASHED_PASSWD"

ssh_pwauth: true
disable_root: false
chpasswd:
  list: |
    root:$USERPASS
  expire: false

write_files:
  - path: /etc/ssh/sshd_config.d/99-password-auth.conf
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
    permissions: '0644'
EOF

if [[ "$IPMODE" != "d" ]]; then
    # Add static network config. Note: interface name may vary; cloud-init tries to match
    # We'll assume 'enp1s0' or 'eth0'. You can adjust if needed.
    cat >> "$MOUNT_POINT/user-data" <<EOF

network:
  version: 2
  ethernets:
    id0:
      match:
        name: en*
      dhcp4: no
      addresses:
        - $STATIC_IP/24
      gateway4: $GATEWAY
      nameservers:
        addresses: [$DNS, 8.8.4.4]
      set-name: enp1s0
EOF
fi

echo
echo "Cloud-init configuration written:"
echo "--- meta-data ---"
cat "$MOUNT_POINT/meta-data"
echo "--- user-data ---"
cat "$MOUNT_POINT/user-data"
echo "-----------------"

# Unmount
umount "$MOUNT_POINT"
echo "CIDATA partition unmounted."

# 7. Final message
echo
echo "================================================"
echo "USB stick is ready! Boot your headless laptop from it."
echo "  - Enter BIOS/UEFI, disable Secure Boot, set USB as first boot device."
echo "  - The system will boot and apply your settings."
echo "  - Wait about 1-2 minutes, then connect via SSH:"
echo "      ssh ${USERNAME}@${STATIC_IP:-<DHCP_IP>}"
echo "      Password: $USERPASS"
echo "================================================"
