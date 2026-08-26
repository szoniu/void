#!/usr/bin/env bash
# tests/test_apple.sh — Apple hardware detection, macOS partition detection,
# and the safety rules that hang off them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-apple.log"
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
source "${LIB_DIR}/apple.sh"

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

assert_true() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — command returned non-zero: $*"
        (( FAIL++ )) || true
    fi
}

assert_false() {
    local desc="$1"; shift
    if "$@"; then
        echo "  FAIL: ${desc} — command unexpectedly returned zero: $*"
        (( FAIL++ )) || true
    else
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    fi
}

echo "=== SPI input model matching ==="

# _apple_has_spi_input prefers the ACPI device; on a test machine that path
# does not exist, so the model fallback is what gets exercised here.
for model in "MacBook10,1" "MacBook8,1" "MacBook9,1" "MacBookPro13,2" "MacBookPro14,3"; do
    APPLE_MODEL="${model}"
    assert_true "${model} -> SPI keyboard" _apple_has_spi_input
done

for model in "MacBookAir7,2" "MacBookPro11,1" "iMac18,2" ""; do
    APPLE_MODEL="${model}"
    assert_false "${model:-<empty>} -> no SPI keyboard" _apple_has_spi_input
done

echo ""
echo "=== macOS filesystem classification ==="

assert_true  "apfs is a macOS filesystem"     apple_fstype_is_macos "apfs"
assert_true  "APFS uppercase is matched"      apple_fstype_is_macos "APFS"
assert_true  "hfsplus is a macOS filesystem"  apple_fstype_is_macos "hfsplus"
assert_false "ext4 is not a macOS filesystem" apple_fstype_is_macos "ext4"
assert_false "ntfs is not a macOS filesystem" apple_fstype_is_macos "ntfs"

echo ""
echo "=== macOS shrink is refused ==="

# The shrink helpers must never claim they can resize APFS/HFS+.
source "${LIB_DIR}/disk.sh"
assert_false "APFS is not shrinkable"    disk_can_shrink_fstype "apfs"
assert_false "HFS+ is not shrinkable"    disk_can_shrink_fstype "hfsplus"
assert_true  "ext4 is still shrinkable"  disk_can_shrink_fstype "ext4"

echo ""
echo "=== macOS partition detection (GPT type GUID) ==="

# Stand in for lsblk: a MacBook layout — Apple ESP, APFS container, Recovery.
lsblk() {
    cat << 'LSBLK'
PATH="/dev/nvme0n1p1" PARTTYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" FSTYPE="vfat"
PATH="/dev/nvme0n1p2" PARTTYPE="7c3457ef-0000-11aa-aa11-00306543ecac" FSTYPE=""
PATH="/dev/nvme0n1p3" PARTTYPE="426f6f74-0000-11aa-aa11-00306543ecac" FSTYPE="hfsplus"
LSBLK
}

declare -gA DETECTED_OSES=()
MACOS_DETECTED=0
detect_macos_partitions

assert_eq "APFS container detected" "macOS (APFS container)" "${DETECTED_OSES[/dev/nvme0n1p2]:-}"
assert_eq "Recovery partition labelled" "macOS Recovery" "${DETECTED_OSES[/dev/nvme0n1p3]:-}"
assert_eq "ESP is not reported as an OS" "" "${DETECTED_OSES[/dev/nvme0n1p1]:-}"
assert_eq "MACOS_DETECTED set" "1" "${MACOS_DETECTED}"

echo ""
echo "=== Recovery alone does not count as an install ==="

lsblk() {
    cat << 'LSBLK'
PATH="/dev/sda1" PARTTYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" FSTYPE="vfat"
PATH="/dev/sda2" PARTTYPE="426f6f74-0000-11aa-aa11-00306543ecac" FSTYPE="hfsplus"
LSBLK
}

declare -gA DETECTED_OSES=()
MACOS_DETECTED=0
detect_macos_partitions

assert_eq "Recovery-only -> MACOS_DETECTED=0" "0" "${MACOS_DETECTED}"
assert_eq "Recovery still listed" "macOS Recovery" "${DETECTED_OSES[/dev/sda2]:-}"

echo ""
echo "=== Detection by filesystem when GUID is absent ==="

# Older/odd media report no PARTTYPE; libblkid's FSTYPE is the fallback.
lsblk() {
    cat << 'LSBLK'
PATH="/dev/sda2" PARTTYPE="" FSTYPE="apfs"
PATH="/dev/sda3" PARTTYPE="" FSTYPE="ext4"
LSBLK
}

declare -gA DETECTED_OSES=()
MACOS_DETECTED=0
detect_macos_partitions

assert_eq "APFS by fstype" "macOS (APFS container)" "${DETECTED_OSES[/dev/sda2]:-}"
assert_eq "ext4 left to the generic detector" "" "${DETECTED_OSES[/dev/sda3]:-}"

unset -f lsblk

echo ""
echo "=== Serialization round-trip ==="

declare -gA DETECTED_OSES=(
    ["/dev/nvme0n1p2"]="macOS (APFS container)"
)
serialize_detected_oses

MACOS_DETECTED=0
LINUX_DETECTED=0
WINDOWS_DETECTED=0
unset DETECTED_OSES
deserialize_detected_oses

assert_eq "macOS survives round-trip" "macOS (APFS container)" "${DETECTED_OSES[/dev/nvme0n1p2]:-}"
assert_eq "macOS restores MACOS_DETECTED" "1" "${MACOS_DETECTED}"
assert_eq "macOS is not counted as Linux" "0" "${LINUX_DETECTED}"
assert_eq "macOS is not counted as Windows" "0" "${WINDOWS_DETECTED}"

echo ""
echo "=== Config plumbing ==="

# The Apple flags must round-trip through config_save/config_load, otherwise
# the chroot phase (a separate process) loses them.
for var in APPLE_DETECTED APPLE_T2_DETECTED APPLE_MODEL APPLE_SPI_INPUT MACOS_DETECTED ENABLE_NIRI; do
    found=0
    for known in "${CONFIG_VARS[@]}"; do
        [[ "${known}" == "${var}" ]] && found=1 && break
    done
    assert_eq "${var} is in CONFIG_VARS" "1" "${found}"
done

found=0
for cp in "${CHECKPOINTS[@]}"; do
    [[ "${cp}" == "apple_quirks" ]] && found=1 && break
done
assert_eq "apple_quirks checkpoint registered" "1" "${found}"

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
