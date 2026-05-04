#!/usr/bin/env bash
set -euo pipefail

ISO="DietPi_VM-x86_64-Trixie_Installer.iso"
TARGET="/dev/sdc"
EFI_PART_SIZE="512M"

echo "=== WARNING: This will ERASE $TARGET entirely ==="
read -rp "Type YES to continue: " confirm
[[ "$confirm" != "YES" ]] && exit 1

# 1. Unmount everything on target
sudo umount "${TARGET}"* 2>/dev/null || true

# 2. Partition: GPT, EFI System (FAT32), Linux root (ext4)
sudo sgdisk --zap-all "$TARGET"
sudo sgdisk -n 1:0:+${EFI_PART_SIZE} -t 1:ef00 -c 1:"EFI" "$TARGET"
sudo sgdisk -n 2:0:0 -t 2:8300 -c 2:"DietPi_root" "$TARGET"
sudo partprobe "$TARGET"
sleep 2

# 3. Format
sudo mkfs.vfat -F32 "${TARGET}1"
sudo mkfs.ext4 -F "${TARGET}2"

# 4. Mount the root partition and EFI
sudo mkdir -p /mnt/root
sudo mount "${TARGET}2" /mnt/root
sudo mkdir -p /mnt/root/boot/efi
sudo mount "${TARGET}1" /mnt/root/boot/efi

# 5. Mount ISO and extract filesystem
mkdir -p /mnt/iso /mnt/squashfs
sudo mount -o loop "$ISO" /mnt/iso
# Find the squashfs file (Debian live)
SQUASHFS=$(find /mnt/iso -name "filesystem.squashfs" -type f | head -1)
[[ -z "$SQUASHFS" ]] && { echo "ERROR: squashfs not found in ISO"; exit 1; }
sudo mount "$SQUASHFS" /mnt/squashfs
sudo rsync -a /mnt/squashfs/ /mnt/root/

# 6. Prepare chroot and install bootloader
sudo mount --bind /dev /mnt/root/dev
sudo mount --bind /dev/pts /mnt/root/dev/pts
sudo mount --bind /proc /mnt/root/proc
sudo mount --bind /sys /mnt/root/sys
sudo cp /etc/resolv.conf /mnt/root/etc/resolv.conf

sudo chroot /mnt/root /bin/bash <<'CHROOT'
# Update package list and install GRUB for UEFI
apt update
apt install -y grub-efi-amd64
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=DietPi --recheck
update-grub

# Set a temporary root password (change on first login)
echo "root:temp1234" | chpasswd

# Enable SSH
systemctl enable ssh

# Ensure network with DHCP (you can later switch to static)
cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en*
Name=eth*
[Network]
DHCP=yes
EOF
systemctl enable systemd-networkd

# Enable DietPi first‑run configuration (the live system may not have it,
# but the installer script will run if present; we'll fetch it later)
CHROOT

# 7. Clean up
sudo umount /mnt/root/dev/pts
sudo umount /mnt/root/dev
sudo umount /mnt/root/proc
sudo umount /mnt/root/sys
sudo umount /mnt/root/boot/efi
sudo umount /mnt/root
sudo umount /mnt/squashfs
sudo umount /mnt/iso

echo "Done. Boot from the USB, then run 'dietpi-update' and 'dietpi-config' to finish setup."
