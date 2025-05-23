#!/bin/bash

# Resolve script location
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# This script is called from our systemd unit file to mount or unmount
# a USB drive.

usage()
{
    echo "Usage: $0 {add|remove} device_name (e.g. sdb1 or sdb)"
    echo "       $0 uninstall"
}

setup_instructions()
{
    SCRIPT_PATH=$(realpath "$0")
    cat <<EOF

# FIRST-TIME SETUP REQUIRED - Run these commands to enable automatic mounting:

# 1. Create the mounting service
sudo tee /etc/systemd/system/usb-mount@.service >/dev/null <<SVC_EOF
[Unit]
Description=Mount USB Drive on %i

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=${SCRIPT_PATH} add %i
ExecStop=${SCRIPT_PATH} remove %i
SVC_EOF

# 2. Add USB detection rules
sudo tee /etc/udev/rules.d/99-local.rules >/dev/null <<UDEV_EOF
KERNEL=="sd[a-z]*", SUBSYSTEMS=="usb", ACTION=="add", RUN+="/bin/systemctl start usb-mount@%k.service"
KERNEL=="sd[a-z]*", SUBSYSTEMS=="usb", ACTION=="remove", RUN+="/bin/systemctl stop usb-mount@%k.service"
UDEV_EOF

# 3. Refresh system services
sudo udevadm control --reload-rules
sudo systemctl daemon-reload

echo "Setup complete! USB drives will now auto-mount"
EOF
    exit 1
}

uninstall_instructions()
{
    cat <<EOF

# COMPLETELY REMOVE AUTO-MOUNTING - Run these commands:

# 1. Remove systemd service
sudo rm -f /etc/systemd/system/usb-mount@.service

# 2. Remove udev rules
sudo rm -f /etc/udev/rules.d/99-local.rules

# 3. Refresh system services
sudo udevadm control --reload-rules
sudo systemctl daemon-reload

# 4. Optional: Remove mount directories (if empty)
sudo rmdir /media/* 2>/dev/null

echo "Uninstall complete! USB auto-mounting removed"
EOF
    exit 1
}

if [[ $# -eq 1 && "$1" == "uninstall" ]]; then
    uninstall_instructions
elif [[ $# -ne 2 ]]; then
    usage
    setup_instructions
    exit 1
fi

ACTION=$1
DEVBASE=$2
DEVICE="/dev/${DEVBASE}"

# See if this drive is already mounted, and if so where
MOUNT_POINT=$(/bin/mount | /bin/grep "^${DEVICE} " | /usr/bin/awk '{ print $3 }')

do_mount()
{
    if [[ -n ${MOUNT_POINT} ]]; then
        echo "Warning: ${DEVICE} is already mounted at ${MOUNT_POINT}"
        exit 1
    fi

    # Get info for this drive: $ID_FS_LABEL, $ID_FS_UUID, and $ID_FS_TYPE
    eval $(/sbin/blkid -o udev ${DEVICE})

    # Figure out a mount point to use
    if [[ -n "${ID_FS_LABEL}" ]]; then
        BASE_LABEL="${ID_FS_LABEL}"
    else
        BASE_LABEL="${DEVBASE}"
    fi

    LABEL="${BASE_LABEL}"
    SUFFIX=1

    # Find unique mount point name
    while /bin/grep -q " /media/${LABEL} " /etc/mtab; do
        LABEL="${BASE_LABEL}-${SUFFIX}"
        ((SUFFIX++))
    done

    MOUNT_POINT="/media/${LABEL}"

    echo "Mount point: ${MOUNT_POINT}"

    /bin/mkdir -p ${MOUNT_POINT}

    # Global mount options
    OPTS="rw,relatime"

    # File system type specific mount options
    if [[ ${ID_FS_TYPE} == "vfat" ]]; then
        OPTS+=",users,gid=100,umask=000,shortname=mixed,utf8=1,flush"
    fi

    if ! /bin/mount -o ${OPTS} ${DEVICE} ${MOUNT_POINT}; then
        echo "Error mounting ${DEVICE} (status = $?)"
        /bin/rmdir ${MOUNT_POINT}
        exit 1
    fi

    echo "**** Mounted ${DEVICE} at ${MOUNT_POINT} ****"
}

do_unmount()
{
    if [[ -z ${MOUNT_POINT} ]]; then
        echo "Warning: ${DEVICE} is not mounted"
    else
        /bin/umount -l ${DEVICE}
        echo "**** Unmounted ${DEVICE}"
    fi

    # Delete all empty dirs in /media that aren't being used as mount
    # points. This is kind of overkill, but if the drive was unmounted
    # prior to removal we no longer know its mount point, and we don't
    # want to leave it orphaned...
    for f in /media/* ; do
        if [[ -n $(/usr/bin/find "$f" -maxdepth 0 -type d -empty) ]]; then
            if ! /bin/grep -q " $f " /etc/mtab; then
                echo "**** Removing mount point $f"
                /bin/rmdir "$f"
            fi
        fi
    done
}

case "${ACTION}" in
    add)
        do_mount
        ;;
    remove)
        do_unmount
        ;;
    *)
        usage
        ;;
esac
