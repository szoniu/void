#!/usr/bin/env bash
# tests/test_infer_config.sh — Test config inference from installed Void system
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-infer.log"
export DRY_RUN=1
export NON_INTERACTIVE=1

TEST_TMPDIR="$(mktemp -d)"
export CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints"
export CHECKPOINT_DIR_SUFFIX="/tmp/void-installer-checkpoints"
export CONFIG_FILE="${TEST_TMPDIR}/void-installer.conf"
export MOUNTPOINT="${TEST_TMPDIR}/mnt"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/config.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — expected '${expected}', got '${actual}'"
        (( FAIL++ )) || true
    fi
}

# Helper: clear all config vars
clear_config_vars() {
    local var
    for var in "${CONFIG_VARS[@]}"; do
        unset "${var}" 2>/dev/null || true
    done
}

# ================================================================
echo "=== Test 1: Full Void system (ext4, zram, LTS kernel, nonfree) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/xbps.d"
mkdir -p "${local_root}/etc/default"
mkdir -p "${local_root}/var/db/xbps"
mkdir -p "${local_root}/etc/sv/zramen"
mkdir -p "${local_root}/var/service"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222-cccc-3333 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
# /etc/fstab
UUID=bbbb-2222-cccc-3333  /          ext4  defaults  0 1
UUID=aaaa-1111            /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/rc.conf" <<'RCCONF'
HOSTNAME="void-test"
KEYMAP="pl"
TIMEZONE="Europe/Warsaw"
RCCONF

echo "void-test" > "${local_root}/etc/hostname"

cat > "${local_root}/etc/default/libc-locales" <<'LOCALE'
# Supported locales
pl_PL.UTF-8 UTF-8
en_US.UTF-8 UTF-8
LOCALE

echo "repository=https://mirror.example.com/current" > "${local_root}/etc/xbps.d/00-repository-main.conf"
echo "repository=https://mirror.example.com/current/nonfree" > "${local_root}/etc/xbps.d/10-repository-nonfree.conf"

# Fake LTS kernel plist
touch "${local_root}/var/db/xbps/.linux-lts-6.1.123_1.x86_64.plist"

# zramen runit service
ln -sf /etc/sv/zramen "${local_root}/var/service/zramen"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Return code 0 (sufficient)" "0" "${rc}"
assert_eq "ROOT_PARTITION" "/dev/sda2" "${ROOT_PARTITION:-}"
assert_eq "TARGET_DISK" "/dev/sda" "${TARGET_DISK:-}"
assert_eq "FILESYSTEM" "ext4" "${FILESYSTEM:-}"
assert_eq "ESP_PARTITION" "/dev/sda1" "${ESP_PARTITION:-}"
assert_eq "HOSTNAME" "void-test" "${HOSTNAME:-}"
assert_eq "TIMEZONE" "Europe/Warsaw" "${TIMEZONE:-}"
assert_eq "LOCALE" "pl_PL.UTF-8" "${LOCALE:-}"
assert_eq "KEYMAP" "pl" "${KEYMAP:-}"
assert_eq "KERNEL_TYPE" "lts" "${KERNEL_TYPE:-}"
assert_eq "MIRROR_URL" "https://mirror.example.com" "${MIRROR_URL:-}"
assert_eq "ENABLE_NONFREE" "yes" "${ENABLE_NONFREE:-}"
assert_eq "SWAP_TYPE" "zram" "${SWAP_TYPE:-}"
assert_eq "PARTITION_SCHEME" "auto" "${PARTITION_SCHEME:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 2: Btrfs with subvolumes ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          btrfs  defaults,subvol=@        0 0
UUID=aaaa-1111  /boot/efi  vfat   defaults                 0 2
UUID=bbbb-2222  /home      btrfs  defaults,subvol=@home    0 0
FSTAB

rc=0
infer_config_from_partition "/dev/sda2" "btrfs" || rc=$?

assert_eq "Return code 0 (sufficient)" "0" "${rc}"
assert_eq "FILESYSTEM btrfs" "btrfs" "${FILESYSTEM:-}"
assert_eq "BTRFS_SUBVOLUMES" "@:/:@home:/home" "${BTRFS_SUBVOLUMES:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 3: _infer_from_xbps_conf — mirror and nonfree detection ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/xbps.d"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

echo "repository=https://void.sakamoto.pl/current" > "${local_root}/etc/xbps.d/00-repository-main.conf"
echo "repository=https://void.sakamoto.pl/current/nonfree" > "${local_root}/etc/xbps.d/10-repository-nonfree.conf"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "MIRROR_URL from xbps.d" "https://void.sakamoto.pl" "${MIRROR_URL:-}"
assert_eq "ENABLE_NONFREE from xbps.d" "yes" "${ENABLE_NONFREE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 4: _infer_from_rc_conf — HOSTNAME, KEYMAP, TIMEZONE ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/rc.conf" <<'RCCONF'
HOSTNAME="rc-host"
KEYMAP="de"
TIMEZONE="Europe/Berlin"
RCCONF

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "HOSTNAME from rc.conf" "rc-host" "${HOSTNAME:-}"
assert_eq "KEYMAP from rc.conf" "de" "${KEYMAP:-}"
assert_eq "TIMEZONE from rc.conf" "Europe/Berlin" "${TIMEZONE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 5: _infer_from_hostname (/etc/hostname fallback) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

# No rc.conf, only /etc/hostname
echo "hostname-only" > "${local_root}/etc/hostname"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "HOSTNAME from /etc/hostname" "hostname-only" "${HOSTNAME:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 6: _infer_from_timezone (/etc/timezone and localtime symlink) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

# No rc.conf, use /etc/timezone
echo "America/New_York" > "${local_root}/etc/timezone"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "TIMEZONE from /etc/timezone" "America/New_York" "${TIMEZONE:-}"

# Test localtime symlink fallback
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc" "${local_root}/usr/share/zoneinfo/Asia"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

# Symlink localtime
ln -sf /usr/share/zoneinfo/Asia/Tokyo "${local_root}/etc/localtime"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "TIMEZONE from localtime symlink" "Asia/Tokyo" "${TIMEZONE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 7: _infer_from_locale (/etc/default/libc-locales) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/default"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/default/libc-locales" <<'LOCALE'
# Default locales
#en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
en_US.UTF-8 UTF-8
LOCALE

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "LOCALE from libc-locales" "de_DE.UTF-8" "${LOCALE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 8: _infer_kernel_type — LTS vs mainline vs default ==="

# LTS kernel
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc" "${local_root}/var/db/xbps"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

touch "${local_root}/var/db/xbps/.linux-lts-6.1.99_1.x86_64.plist"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?
assert_eq "KERNEL_TYPE lts" "lts" "${KERNEL_TYPE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# Mainline kernel
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc" "${local_root}/var/db/xbps"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

touch "${local_root}/var/db/xbps/.linux-6.9.0_1.x86_64.plist"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?
assert_eq "KERNEL_TYPE mainline" "mainline" "${KERNEL_TYPE:-}"

rm -rf "${_RESUME_TEST_DIR}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 9: _infer_swap_type — zramen service, swap file, none ==="

# zramen service dir
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/sv/zramen" "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?
assert_eq "SWAP_TYPE zram (service dir)" "zram" "${SWAP_TYPE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# Swap file
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc" "${local_root}/var"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

touch "${local_root}/var/swapfile"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?
assert_eq "SWAP_TYPE file (swapfile)" "file" "${SWAP_TYPE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# No swap at all
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?
assert_eq "SWAP_TYPE none (no swap detected)" "none" "${SWAP_TYPE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 10: _infer_sufficient_config (no INIT_SYSTEM requirement) ==="

# Sufficient: ROOT + ESP + FILESYSTEM + TARGET_DISK
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?
assert_eq "Sufficient with just fstab (Void always uses runit)" "0" "${rc}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 11: Missing fstab -> insufficient (no ESP) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
unset _INFER_UUID_MAP

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Return code 1 (insufficient -- no fstab)" "1" "${rc}"
assert_eq "ROOT_PARTITION still set from args" "/dev/sda2" "${ROOT_PARTITION:-}"
assert_eq "ESP_PARTITION empty" "" "${ESP_PARTITION:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 12: Dual-boot (ESP on different disk) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sdb2"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sdb2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

rc=0
infer_config_from_partition "/dev/sdb2" "ext4" || rc=$?

assert_eq "Return code 0 (sufficient)" "0" "${rc}"
assert_eq "TARGET_DISK sdb" "/dev/sdb" "${TARGET_DISK:-}"
assert_eq "ESP_PARTITION different disk" "/dev/sda1" "${ESP_PARTITION:-}"
assert_eq "PARTITION_SCHEME dual-boot" "dual-boot" "${PARTITION_SCHEME:-}"
assert_eq "ESP_REUSE" "yes" "${ESP_REUSE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 13: NVMe partition -> correct TARGET_DISK ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/nvme0n1p2"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/nvme0n1p1
bbbb-2222 /dev/nvme0n1p2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

rc=0
infer_config_from_partition "/dev/nvme0n1p2" "ext4" || rc=$?

assert_eq "Return code 0" "0" "${rc}"
assert_eq "TARGET_DISK nvme" "/dev/nvme0n1" "${TARGET_DISK:-}"
assert_eq "ROOT_PARTITION nvme" "/dev/nvme0n1p2" "${ROOT_PARTITION:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 14: _partition_to_disk helper ==="

assert_eq "sda2 -> sda" "/dev/sda" "$(_partition_to_disk /dev/sda2)"
assert_eq "nvme0n1p3 -> nvme0n1" "/dev/nvme0n1" "$(_partition_to_disk /dev/nvme0n1p3)"
assert_eq "mmcblk0p1 -> mmcblk0" "/dev/mmcblk0" "$(_partition_to_disk /dev/mmcblk0p1)"
assert_eq "vda1 -> vda" "/dev/vda" "$(_partition_to_disk /dev/vda1)"

# ================================================================
echo ""
echo "=== Test 15: Swap partition in fstab ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda3"
mkdir -p "${local_root}/etc"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
dddd-4444-eeee-5555 /dev/sda2
bbbb-2222-cccc-3333 /dev/sda3
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222-cccc-3333  /          ext4  defaults  0 1
UUID=aaaa-1111            /boot/efi  vfat  defaults  0 2
UUID=dddd-4444-eeee-5555  none       swap  sw        0 0
FSTAB

rc=0
infer_config_from_partition "/dev/sda3" "ext4" || rc=$?

assert_eq "SWAP_TYPE partition (from fstab)" "partition" "${SWAP_TYPE:-}"
assert_eq "SWAP_PARTITION" "/dev/sda2" "${SWAP_PARTITION:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 16: infer_config_from_partition full flow ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/xbps.d"
mkdir -p "${local_root}/etc/default"
mkdir -p "${local_root}/var/db/xbps"
mkdir -p "${local_root}/etc/sv/zramen"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          xfs   defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/rc.conf" <<'RCCONF'
HOSTNAME="full-flow"
KEYMAP="us"
TIMEZONE="US/Eastern"
RCCONF

cat > "${local_root}/etc/default/libc-locales" <<'LOCALE'
en_US.UTF-8 UTF-8
LOCALE

echo "repository=https://repo-default.voidlinux.org/current" > "${local_root}/etc/xbps.d/00-repository-main.conf"

touch "${local_root}/var/db/xbps/.linux-6.9.0_1.x86_64.plist"

rc=0
infer_config_from_partition "/dev/sda2" "xfs" || rc=$?

assert_eq "Full flow rc" "0" "${rc}"
assert_eq "Full flow ROOT_PARTITION" "/dev/sda2" "${ROOT_PARTITION:-}"
assert_eq "Full flow FILESYSTEM" "xfs" "${FILESYSTEM:-}"
assert_eq "Full flow HOSTNAME" "full-flow" "${HOSTNAME:-}"
assert_eq "Full flow KEYMAP" "us" "${KEYMAP:-}"
assert_eq "Full flow TIMEZONE" "US/Eastern" "${TIMEZONE:-}"
assert_eq "Full flow LOCALE" "en_US.UTF-8" "${LOCALE:-}"
assert_eq "Full flow KERNEL_TYPE" "mainline" "${KERNEL_TYPE:-}"
assert_eq "Full flow MIRROR_URL" "https://repo-default.voidlinux.org" "${MIRROR_URL:-}"
assert_eq "Full flow SWAP_TYPE" "zram" "${SWAP_TYPE:-}"

rm -rf "${_RESUME_TEST_DIR}"

unset _RESUME_TEST_DIR _INFER_UUID_MAP

# Cleanup
rm -rf "${TEST_TMPDIR}"
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
