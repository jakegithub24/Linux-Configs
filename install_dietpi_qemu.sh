#!/usr/bin/env bash
set -euo pipefail

DOWNLOAD_DIR="$HOME/Downloads/DietPi"
ISO_FILE="DietPi_VM-x86_64-Trixie_Installer.iso"
TARGET_DEV="/dev/sdc"
VM_NAME="DietPi_Installer"
VMDK_FILE="$HOME/VirtualBox VMs/usb_raw.vmdk"

cd "$DOWNLOAD_DIR" || exit 1
[[ -f "$ISO_FILE" ]] || { echo "ERROR: $ISO_FILE missing."; exit 1; }

# --- 1. Ensure user is in disk group ---
if ! groups | grep -q '\bdisk\b'; then
    echo "You do NOT have the 'disk' group active. Adding now..."
    sudo usermod -aG disk "$USER"
    echo "!!! You MUST log out and log back in for the group change to take effect."
    echo "    After logging back in, re-run this script."
    exit 1
fi

# --- 2. Set permissions on the USB device ---
sudo chmod 666 "$TARGET_DEV"

# --- 3. Remove previous VMDK and VM if they exist ---
sudo rm -f "$VMDK_FILE"
if VBoxManage showvminfo "$VM_NAME" &>/dev/null; then
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    VBoxManage unregistervm "$VM_NAME" --delete
fi

# --- 4. Create raw disk mapping with correct ownership ---
echo "Creating raw disk mapping..."
sudo VBoxManage createmedium disk --filename "$VMDK_FILE" --format=VMDK --variant RawDisk --property RawDrive="$TARGET_DEV"
sudo chown "$USER" "$VMDK_FILE"   # *** This fixes the VERR_ACCESS_DENIED error ***

# --- 5. Create and configure VM ---
VBoxManage createvm --name "$VM_NAME" --ostype Debian_64 --register
VBoxManage modifyvm "$VM_NAME" --memory 4096 --cpus 2 --ioapic on --firmware efi
VBoxManage modifyvm "$VM_NAME" --nic1 nat --nictype1 82540EM --cableconnected1 on

# --- 6. Attach storage ---
VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci
VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$VMDK_FILE"
VBoxManage storagectl "$VM_NAME" --name "IDE Controller" --add ide
VBoxManage storageattach "$VM_NAME" --storagectl "IDE Controller" --port 0 --device 0 --type dvddrive --medium "$ISO_FILE"

# --- 7. Boot from DVD ---
VBoxManage modifyvm "$VM_NAME" --boot1 dvd --boot2 disk --boot3 none --boot4 none

# --- 8. Start VM ---
echo "Starting the VM..."
VBoxManage startvm "$VM_NAME" --type gui

echo ""
echo "Install DietPi in the VM. Target disk: /dev/sda (your 8GB USB)."
echo "After installation, close the VM and press Enter."
read -p "Press Enter to clean up..." dummy

# --- 9. Cleanup ---
VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
sleep 2
VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --medium none
VBoxManage storageattach "$VM_NAME" --storagectl "IDE Controller" --port 0 --device 0 --medium none
VBoxManage unregistervm "$VM_NAME" --delete
sudo rm -f "$VMDK_FILE"
sudo chmod 660 "$TARGET_DEV" 2>/dev/null || true
echo "Done. USB drive should now be bootable."
