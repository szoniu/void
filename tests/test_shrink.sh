#!/usr/bin/env bash
# tests/test_shrink.sh — Test partition shrink planning, helpers and safety gate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-shrink.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/disk.sh"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' not found in '${haystack}'"
        (( FAIL++ )) || true
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' unexpectedly found in '${haystack}'"
        (( FAIL++ )) || true
    fi
}

# Helper: collect all action descriptions
_get_plan_text() {
    local text=""
    local action
    for action in "${DISK_ACTIONS[@]}"; do
        text+="${action%%|||*} | "
    done
    echo "${text}"
}

echo "=== Test: VOID_MIN_SIZE_MIB constant ==="

assert_eq "VOID_MIN_SIZE_MIB is 10240" "10240" "${VOID_MIN_SIZE_MIB}"

echo ""
echo "=== Test: disk_can_shrink_fstype ==="

disk_can_shrink_fstype "ntfs" && rc=0 || rc=$?
assert_eq "ntfs can shrink" "0" "${rc}"

disk_can_shrink_fstype "ext4" && rc=0 || rc=$?
assert_eq "ext4 can shrink" "0" "${rc}"

disk_can_shrink_fstype "btrfs" && rc=0 || rc=$?
assert_eq "btrfs can shrink" "0" "${rc}"

disk_can_shrink_fstype "xfs" && rc=0 || rc=$?
assert_eq "xfs cannot shrink" "1" "${rc}"

disk_can_shrink_fstype "swap" && rc=0 || rc=$?
assert_eq "swap cannot shrink" "1" "${rc}"

disk_can_shrink_fstype "vfat" && rc=0 || rc=$?
assert_eq "vfat cannot shrink" "1" "${rc}"

echo ""
echo "=== Test: disk_get_free_space_mib (DRY_RUN) ==="

_DRY_RUN_FREE_SPACE_MIB=500
result=$(disk_get_free_space_mib "/dev/sda")
assert_eq "Free space returns dry-run value" "500" "${result}"

_DRY_RUN_FREE_SPACE_MIB=0
result=$(disk_get_free_space_mib "/dev/sda")
assert_eq "Free space returns 0 when none" "0" "${result}"

echo ""
echo "=== Test: disk_get_partition_size_mib (DRY_RUN) ==="

_DRY_RUN_PART_SIZE_MIB=102400
result=$(disk_get_partition_size_mib "/dev/sda2")
assert_eq "Partition size returns dry-run value" "102400" "${result}"

echo ""
echo "=== Test: disk_get_partition_used_mib (DRY_RUN) ==="

_DRY_RUN_PART_USED_MIB=51200
result=$(disk_get_partition_used_mib "/dev/sda2" "ntfs")
assert_eq "Partition used returns dry-run value" "51200" "${result}"

# Reset so the shrink safety gate is not triggered by subsequent plan tests
_DRY_RUN_PART_USED_MIB=0

echo ""
echo "=== Test: disk_plan_shrink (NTFS) ==="

disk_plan_reset
TARGET_DISK="/dev/sda"
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB=80000

disk_plan_shrink

plan_text=$(_get_plan_text)
assert_contains "NTFS plan has dry-run validation" "Validate NTFS shrink" "${plan_text}"
assert_contains "NTFS plan has NTFS shrink" "Shrink NTFS filesystem" "${plan_text}"
assert_contains "NTFS plan has partition table resize" "partition table" "${plan_text}"
assert_eq "NTFS plan action count" "4" "${#DISK_ACTIONS[@]}"

echo ""
echo "=== Test: disk_plan_shrink (ext4) ==="

disk_plan_reset
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ext4"
SHRINK_NEW_SIZE_MIB=60000

disk_plan_shrink

plan_text=$(_get_plan_text)
assert_contains "ext4 plan has e2fsck" "Check ext4" "${plan_text}"
assert_contains "ext4 plan has resize2fs" "Shrink ext4" "${plan_text}"
assert_contains "ext4 plan has partition table resize" "partition table" "${plan_text}"
assert_eq "ext4 plan action count" "4" "${#DISK_ACTIONS[@]}"

echo ""
echo "=== Test: disk_plan_shrink (btrfs) ==="

disk_plan_reset
SHRINK_PARTITION="/dev/sda3"
SHRINK_PARTITION_FSTYPE="btrfs"
SHRINK_NEW_SIZE_MIB=50000

disk_plan_shrink

plan_text=$(_get_plan_text)
assert_contains "btrfs plan has btrfs shrink" "Shrink btrfs filesystem" "${plan_text}"
assert_contains "btrfs plan has partition table resize" "partition table" "${plan_text}"
assert_eq "btrfs plan action count" "3" "${#DISK_ACTIONS[@]}"

echo ""
echo "=== Test: disk_plan_shrink safety gate (new size below used) ==="

disk_plan_reset
_DRY_RUN_PART_USED_MIB=90000
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB=80000

rc=0
disk_plan_shrink || rc=$?
assert_eq "Shrink below used space is refused (rc=1)" "1" "${rc}"
assert_eq "No actions queued when refused" "0" "${#DISK_ACTIONS[@]}"
_DRY_RUN_PART_USED_MIB=0

echo ""
echo "=== Test: disk_plan_dualboot with SHRINK_PARTITION ==="

disk_plan_reset
TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
PARTITION_SCHEME="dual-boot"
ESP_PARTITION="/dev/sda1"
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB=80000
unset ROOT_PARTITION 2>/dev/null || true

disk_plan_dualboot

plan_text=$(_get_plan_text)
assert_contains "Dualboot+shrink has NTFS shrink" "Shrink NTFS filesystem" "${plan_text}"
assert_contains "Dualboot+shrink has root format" "ext4" "${plan_text}"
assert_contains "Dualboot+shrink has sfdisk append" "free space" "${plan_text}"

echo ""
echo "=== Test: disk_plan_dualboot without shrink ==="

disk_plan_reset
unset SHRINK_PARTITION 2>/dev/null || true
unset ROOT_PARTITION 2>/dev/null || true

disk_plan_dualboot

plan_text=$(_get_plan_text)
assert_not_contains "No-shrink dualboot has no NTFS shrink" "Shrink NTFS filesystem" "${plan_text}"
assert_contains "No-shrink dualboot has root format" "ext4" "${plan_text}"

echo ""
echo "=== Test: CONFIG_VARS includes shrink variables ==="

found_shrink_part=0
found_shrink_fstype=0
found_shrink_size=0
for v in "${CONFIG_VARS[@]}"; do
    case "${v}" in
        SHRINK_PARTITION) found_shrink_part=1 ;;
        SHRINK_PARTITION_FSTYPE) found_shrink_fstype=1 ;;
        SHRINK_NEW_SIZE_MIB) found_shrink_size=1 ;;
    esac
done
assert_eq "CONFIG_VARS has SHRINK_PARTITION" "1" "${found_shrink_part}"
assert_eq "CONFIG_VARS has SHRINK_PARTITION_FSTYPE" "1" "${found_shrink_fstype}"
assert_eq "CONFIG_VARS has SHRINK_NEW_SIZE_MIB" "1" "${found_shrink_size}"

echo ""
echo "=== Test: Config round-trip with shrink vars ==="

SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB="80000"
TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
HOSTNAME="testbox"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KERNEL_TYPE="mainline"
GPU_VENDOR="intel"
USERNAME="user"
ROOT_PASSWORD_HASH='$6$test'
USER_PASSWORD_HASH='$6$test'

tmpfile=$(mktemp)
config_save "${tmpfile}"

# Clear and reload
unset SHRINK_PARTITION SHRINK_PARTITION_FSTYPE SHRINK_NEW_SIZE_MIB
config_load "${tmpfile}"

assert_eq "Round-trip SHRINK_PARTITION" "/dev/sda2" "${SHRINK_PARTITION:-}"
assert_eq "Round-trip SHRINK_PARTITION_FSTYPE" "ntfs" "${SHRINK_PARTITION_FSTYPE:-}"
assert_eq "Round-trip SHRINK_NEW_SIZE_MIB" "80000" "${SHRINK_NEW_SIZE_MIB:-}"

rm -f "${tmpfile}"

echo ""
echo "=== Test: validate_config with shrink vars ==="

# Valid shrink config
PARTITION_SCHEME="dual-boot"
ESP_PARTITION="/dev/sda1"
SWAP_TYPE="zram"
DESKTOP_TYPE="kde"
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB="80000"

errors=$(validate_config) && rc=0 || rc=$?
assert_eq "Valid shrink config passes" "0" "${rc}"

# Invalid fstype
SHRINK_PARTITION_FSTYPE="xfs"
errors=$(validate_config) && rc=0 || rc=$?
assert_eq "Invalid shrink fstype fails" "1" "${rc}"
assert_contains "Error mentions fstype" "SHRINK_PARTITION_FSTYPE" "${errors}"

# Missing size
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB=""
errors=$(validate_config) && rc=0 || rc=$?
assert_eq "Missing shrink size fails" "1" "${rc}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
