#!/usr/bin/env bash
# constants.sh — Global constants for the Void installer
source "${LIB_DIR}/protection.sh"

readonly INSTALLER_VERSION="1.0.0"
readonly INSTALLER_NAME="Void Linux TUI Installer"

# Paths (use defaults, allow override from environment)
: "${MOUNTPOINT:=/mnt/void}"
: "${CHROOT_INSTALLER_DIR:=/tmp/void-installer}"
: "${LOG_FILE:=/tmp/void-installer.log}"
: "${CHECKPOINT_DIR:=/tmp/void-installer-checkpoints}"
: "${CHECKPOINT_DIR_SUFFIX:=/tmp/void-installer-checkpoints}"
: "${CONFIG_FILE:=/tmp/void-installer.conf}"

# Void ROOTFS URLs
readonly VOID_REPO_BASE="https://repo-default.voidlinux.org"
readonly ROOTFS_BASE_URL="${VOID_REPO_BASE}/live/current"
readonly ROOTFS_FILENAME_PATTERN="void-x86_64-ROOTFS-*.tar.xz"
readonly ROOTFS_SHA256_URL="${ROOTFS_BASE_URL}/sha256sum.txt"

# Partition sizes (MiB)
readonly ESP_SIZE_MIB=512
readonly SWAP_DEFAULT_SIZE_MIB=4096

# GPT partition type GUIDs (for sfdisk)
readonly GPT_TYPE_EFI="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
readonly GPT_TYPE_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
readonly GPT_TYPE_SWAP="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"

# GRUB
readonly GRUB_PLATFORMS="efi-64"

# Timeouts
readonly COUNTDOWN_DEFAULT=10
readonly DIALOG_TIMEOUT=0

# Exit codes for TUI screens
readonly TUI_NEXT=0
readonly TUI_BACK=1
readonly TUI_ABORT=2

# Checkpoint names
readonly -a CHECKPOINTS=(
    "preflight"
    "disks"
    "rootfs_download"
    "rootfs_verify"
    "rootfs_extract"
    "xbps_preconfig"
    "chroot"
    # Inner chroot checkpoints:
    "xbps_update"
    "system_config"
    "kernel"
    "fstab"
    "networking"
    "bootloader"
    "swap_setup"
    "desktop"
    "users"
    "extras"
    "finalize"
)

# Configuration variable names (for save/load)
readonly -a CONFIG_VARS=(
    TARGET_DISK
    PARTITION_SCHEME
    FILESYSTEM
    BTRFS_SUBVOLUMES
    SWAP_TYPE
    SWAP_SIZE_MIB
    HOSTNAME
    MIRROR_URL
    TIMEZONE
    LOCALE
    KEYMAP
    KERNEL_TYPE
    GPU_VENDOR
    GPU_DRIVER
    GPU_USE_NVIDIA_OPEN
    DESKTOP_EXTRAS
    ROOT_PASSWORD_HASH
    USERNAME
    USER_PASSWORD_HASH
    USER_GROUPS
    EXTRA_PACKAGES
    ENABLE_NONFREE
    ESP_PARTITION
    ESP_REUSE
    ROOT_PARTITION
    SWAP_PARTITION
    BOOT_PARTITION
    WINDOWS_DETECTED
    LINUX_DETECTED
    DETECTED_OSES_SERIALIZED
)
