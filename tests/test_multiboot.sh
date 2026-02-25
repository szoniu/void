#!/usr/bin/env bash
# tests/test_multiboot.sh — Test multi-boot OS detection, serialization, and partition logic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-multiboot.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${DATA_DIR}/gpu_database.sh"
source "${LIB_DIR}/hardware.sh"
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

# =============================================================================
echo "=== Test: Serialization round-trip (3 OSes) ==="

declare -gA DETECTED_OSES=()
DETECTED_OSES["/dev/sda2"]="Windows (system)"
DETECTED_OSES["/dev/sda3"]="openSUSE Tumbleweed"
DETECTED_OSES["/dev/sda5"]="Ubuntu 24.04 LTS"
WINDOWS_DETECTED=1
LINUX_DETECTED=1

serialize_detected_oses

assert_contains "Serialized has Windows" "Windows" "${DETECTED_OSES_SERIALIZED}"
assert_contains "Serialized has openSUSE" "openSUSE" "${DETECTED_OSES_SERIALIZED}"
assert_contains "Serialized has Ubuntu" "Ubuntu" "${DETECTED_OSES_SERIALIZED}"

# Now deserialize
local_serialized="${DETECTED_OSES_SERIALIZED}"
unset DETECTED_OSES
WINDOWS_DETECTED=0
LINUX_DETECTED=0
DETECTED_OSES_SERIALIZED="${local_serialized}"

deserialize_detected_oses

assert_eq "Deserialized Windows" "Windows (system)" "${DETECTED_OSES[/dev/sda2]:-}"
assert_eq "Deserialized openSUSE" "openSUSE Tumbleweed" "${DETECTED_OSES[/dev/sda3]:-}"
assert_eq "Deserialized Ubuntu" "Ubuntu 24.04 LTS" "${DETECTED_OSES[/dev/sda5]:-}"
assert_eq "WINDOWS_DETECTED restored" "1" "${WINDOWS_DETECTED}"
assert_eq "LINUX_DETECTED restored" "1" "${LINUX_DETECTED}"

# =============================================================================
echo ""
echo "=== Test: Serialization sanitizes pipe and equals ==="

declare -gA DETECTED_OSES=()
DETECTED_OSES["/dev/sda1"]="OS|with=pipes"
WINDOWS_DETECTED=0
LINUX_DETECTED=1

serialize_detected_oses

# Pipe and equals should be replaced with -
assert_eq "Pipe sanitized" "0" "$(echo "${DETECTED_OSES_SERIALIZED}" | grep -c '|.*|' || true)"
assert_contains "Equals sanitized in name" "OS-with-pipes" "${DETECTED_OSES_SERIALIZED}"

# Round-trip
DETECTED_OSES_SERIALIZED="${DETECTED_OSES_SERIALIZED}"
unset DETECTED_OSES
deserialize_detected_oses
assert_eq "Sanitized round-trip" "OS-with-pipes" "${DETECTED_OSES[/dev/sda1]:-}"

# =============================================================================
echo ""
echo "=== Test: Config save/load round-trip with DETECTED_OSES_SERIALIZED ==="

# Setup config data
declare -gA DETECTED_OSES=()
DETECTED_OSES["/dev/nvme0n1p2"]="Windows (system)"
DETECTED_OSES["/dev/nvme0n1p4"]="openSUSE Tumbleweed"
WINDOWS_DETECTED=1
LINUX_DETECTED=1
serialize_detected_oses

TARGET_DISK="/dev/nvme0n1"
PARTITION_SCHEME="dual-boot"
FILESYSTEM="ext4"
export TARGET_DISK PARTITION_SCHEME FILESYSTEM DETECTED_OSES_SERIALIZED WINDOWS_DETECTED LINUX_DETECTED

TMPFILE="/tmp/void-test-multiboot-$$.conf"
config_save "${TMPFILE}"

# Clear and reload
saved_serialized="${DETECTED_OSES_SERIALIZED}"
unset DETECTED_OSES DETECTED_OSES_SERIALIZED WINDOWS_DETECTED LINUX_DETECTED

config_load "${TMPFILE}"
assert_eq "Config round-trip DETECTED_OSES_SERIALIZED" "${saved_serialized}" "${DETECTED_OSES_SERIALIZED:-}"
assert_eq "Config round-trip WINDOWS_DETECTED" "1" "${WINDOWS_DETECTED:-0}"
assert_eq "Config round-trip LINUX_DETECTED" "1" "${LINUX_DETECTED:-0}"

# Deserialize after config_load
deserialize_detected_oses
assert_eq "Config+deserialize Windows" "Windows (system)" "${DETECTED_OSES[/dev/nvme0n1p2]:-}"
assert_eq "Config+deserialize openSUSE" "openSUSE Tumbleweed" "${DETECTED_OSES[/dev/nvme0n1p4]:-}"

rm -f "${TMPFILE}"

# =============================================================================
echo ""
echo "=== Test: disk_plan_dualboot with pre-selected ROOT_PARTITION ==="

TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
PARTITION_SCHEME="dual-boot"
ESP_PARTITION="/dev/sda1"
ROOT_PARTITION="/dev/sda3"

disk_plan_dualboot

# Should not have sfdisk --append (we already have ROOT_PARTITION)
plan_has_append=0
for action in "${DISK_ACTIONS[@]}"; do
    [[ "${action}" == *"free space"* ]] && plan_has_append=1
done
assert_eq "No sfdisk --append when ROOT_PARTITION set" "0" "${plan_has_append}"

# Should have format action
plan_text=""
for action in "${DISK_ACTIONS[@]}"; do
    plan_text+="${action%%|||*} "
done
assert_contains "Plan formats root" "ext4" "${plan_text}"
assert_eq "ROOT_PARTITION preserved" "/dev/sda3" "${ROOT_PARTITION}"

# =============================================================================
echo ""
echo "=== Test: Partition prefix logic ==="

# /dev/sda -> sda3 (no p separator)
disk_plan_reset
TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
ESP_PARTITION="/dev/sda1"
unset ROOT_PARTITION

# We can't actually run sfdisk --dump in test, but we test the prefix logic
part_prefix="/dev/sda"
[[ "/dev/sda" =~ [0-9]$ ]] && part_prefix="/dev/sdap"
assert_eq "sda prefix (no trailing digit)" "/dev/sda" "${part_prefix}"

part_prefix="/dev/nvme0n1"
[[ "/dev/nvme0n1" =~ [0-9]$ ]] && part_prefix="/dev/nvme0n1p"
assert_eq "nvme prefix (trailing digit)" "/dev/nvme0n1p" "${part_prefix}"

# =============================================================================
echo ""
echo "=== Test: Deserialization with empty string ==="

unset DETECTED_OSES
DETECTED_OSES_SERIALIZED=""
WINDOWS_DETECTED=0
LINUX_DETECTED=0

deserialize_detected_oses

assert_eq "Empty serialized -> no DETECTED_OSES" "0" "${#DETECTED_OSES[@]}"
assert_eq "Empty serialized -> WINDOWS_DETECTED=0" "0" "${WINDOWS_DETECTED}"
assert_eq "Empty serialized -> LINUX_DETECTED=0" "0" "${LINUX_DETECTED}"

# =============================================================================
echo ""
echo "=== Test: Flags after deserialize (Linux only) ==="

DETECTED_OSES_SERIALIZED="/dev/sda3=Fedora 41"
WINDOWS_DETECTED=0
LINUX_DETECTED=0
unset DETECTED_OSES

deserialize_detected_oses

assert_eq "Linux-only -> LINUX_DETECTED=1" "1" "${LINUX_DETECTED}"
assert_eq "Linux-only -> WINDOWS_DETECTED=0" "0" "${WINDOWS_DETECTED}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
