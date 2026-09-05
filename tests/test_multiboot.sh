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

assert_true() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    else
        echo "  FAIL: ${desc}"; (( FAIL++ )) || true
    fi
}

assert_false() {
    local desc="$1"; shift
    if "$@"; then
        echo "  FAIL: ${desc}"; (( FAIL++ )) || true
    else
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    fi
}

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

# We can't actually run sfdisk --dump in test, but we test the prefix logic.
# Disk path comes from a variable so the regex is exercised, not a constant.
disk_dev="/dev/sda"
part_prefix="${disk_dev}"
[[ "${disk_dev}" =~ [0-9]$ ]] && part_prefix="${disk_dev}p"
assert_eq "sda prefix (no trailing digit)" "/dev/sda" "${part_prefix}"

disk_dev="/dev/nvme0n1"
part_prefix="${disk_dev}"
[[ "${disk_dev}" =~ [0-9]$ ]] && part_prefix="${disk_dev}p"
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

echo ""
echo "=== BitLocker detection (Forgejo #17) ==="

# Windows 11 24H2 encrypts by default, so this is the ordinary case now. An
# encrypted partition cannot be mounted and has no readable /Windows/System32,
# so without this the disk carrying the whole Windows install looks EMPTY:
# no warning, no ERASE prompt. Same failure as macOS before APFS detection.

# Case 1: libblkid new enough to name the type.
lsblk() {
    cat << 'LSBLK'
/dev/nvme0n1 disk
/dev/nvme0n1p1 part vfat
/dev/nvme0n1p3 part BitLocker
LSBLK
}
declare -gA DETECTED_OSES=()
WINDOWS_DETECTED=0
BITLOCKER_DETECTED=0
BITLOCKER_PARTITIONS=""
detect_bitlocker >/dev/null 2>&1

assert_eq "BitLocker partition labelled" "Windows (BitLocker encrypted)" \
    "${DETECTED_OSES[/dev/nvme0n1p3]:-}"
assert_eq "BITLOCKER_DETECTED set" "1" "${BITLOCKER_DETECTED}"
assert_eq "counts as Windows (this is what forces ERASE)" "1" "${WINDOWS_DETECTED}"
assert_eq "partition recorded" "/dev/nvme0n1p3" "${BITLOCKER_PARTITIONS}"

# Case 2: the dangerous one — libblkid too old (< util-linux 2.30) reports NO
# fstype at all, so the partition reads as unused space. Detection has to fall
# back to the volume header, which is why _partition_has_bitlocker_signature
# works on a plain file: that is exactly what the test feeds it.
BL_IMG="${TMPDIR:-/tmp}/void-test-bitlocker.img"
printf '\xeb\x58\x90-FVE-FS-' > "${BL_IMG}"
dd if=/dev/zero bs=1 count=496 >> "${BL_IMG}" 2>/dev/null
NTFS_IMG="${TMPDIR:-/tmp}/void-test-ntfs.img"
printf '\xeb\x52\x90NTFS    ' > "${NTFS_IMG}"
dd if=/dev/zero bs=1 count=496 >> "${NTFS_IMG}" 2>/dev/null

assert_true "volume signature recognised on a header with no fstype" \
    _partition_has_bitlocker_signature "${BL_IMG}"
assert_false "plain NTFS is NOT mistaken for BitLocker" \
    _partition_has_bitlocker_signature "${NTFS_IMG}"

lsblk() {
    printf '%s part \n' "${BL_IMG}"
}
declare -gA DETECTED_OSES=()
WINDOWS_DETECTED=0
BITLOCKER_DETECTED=0
BITLOCKER_PARTITIONS=""
detect_bitlocker >/dev/null 2>&1
assert_eq "empty fstype + signature is still detected" "1" "${BITLOCKER_DETECTED}"

rm -f "${BL_IMG}" "${NTFS_IMG}"
unset -f lsblk

# Case 3: a resumed install must not forget that Windows is encrypted — the
# flag is what gates the shrink path.
DETECTED_OSES_SERIALIZED="/dev/nvme0n1p3=Windows (BitLocker encrypted)"
WINDOWS_DETECTED=0
BITLOCKER_DETECTED=0
BITLOCKER_PARTITIONS=""
unset DETECTED_OSES
deserialize_detected_oses
assert_eq "BitLocker flag survives serialize/deserialize" "1" "${BITLOCKER_DETECTED}"
assert_eq "partition list restored" "/dev/nvme0n1p3" "${BITLOCKER_PARTITIONS}"

# Case 4: the shrink gate. ntfsresize sees ciphertext, not a filesystem.
assert_true "BitLocker is not shrinkable" bitlocker_fstype_is_encrypted "BitLocker"
assert_true "case-insensitive" bitlocker_fstype_is_encrypted "bitlocker"
assert_false "plain ntfs stays shrinkable" bitlocker_fstype_is_encrypted "ntfs"
assert_false "disk_can_shrink_fstype refuses BitLocker" disk_can_shrink_fstype "BitLocker"

# Case 6: idempotency. The production caller does NOT reset these — the earlier
# version of this test did, once per case, which is precisely what hid the bug:
# detect_bitlocker inherited BITLOCKER_PARTITIONS instead of resetting it. That
# matters twice over: the variable is in CONFIG_VARS, so it arrives from a
# preset before hardware detection runs, and screen_hw_detect can be re-entered
# via the wizard's back navigation. A stale path makes the probe loop skip that
# device, hiding a real OS and downgrading the ERASE gate.
lsblk() {
    cat << 'LSBLK'
/dev/nvme0n1p3 part BitLocker
LSBLK
}
declare -gA DETECTED_OSES=()
WINDOWS_DETECTED=0
BITLOCKER_DETECTED=0
BITLOCKER_PARTITIONS=""
detect_bitlocker >/dev/null 2>&1
detect_bitlocker >/dev/null 2>&1   # deliberately NOT resetting in between
assert_eq "second scan does not duplicate entries" "/dev/nvme0n1p3" "${BITLOCKER_PARTITIONS}"

# ...and a device that is no longer encrypted must disappear from the list,
# rather than lingering and suppressing OS detection on that path.
lsblk() {
    cat << 'LSBLK'
/dev/nvme0n1p3 part ntfs
LSBLK
}
declare -gA DETECTED_OSES=()
detect_bitlocker >/dev/null 2>&1
assert_eq "stale partition drops out of the list" "" "${BITLOCKER_PARTITIONS}"
assert_eq "stale flag is cleared too" "0" "${BITLOCKER_DETECTED}"

# Case 7: the signature read must not touch whole disks, optical drives, loop or
# zram devices — a raw read of LBA0 from a drive with a damaged disc goes through
# kernel SCSI retries and freezes hardware detection with nothing on screen.
PROBED=""
_partition_has_bitlocker_signature() { PROBED+="$1 "; return 1; }
lsblk() {
    cat << 'LSBLK'
/dev/sda disk
/dev/sr0 rom
/dev/loop0 loop
/dev/zram0 disk
/dev/sda1 part
LSBLK
}
declare -gA DETECTED_OSES=()
BITLOCKER_DETECTED=0
BITLOCKER_PARTITIONS=""
detect_bitlocker >/dev/null 2>&1
assert_eq "signature probe only runs on partitions" "/dev/sda1 " "${PROBED}"
unset -f _partition_has_bitlocker_signature
unset -f lsblk

# Case 8: state must not survive a wipe — after the auto scheme erases the disk,
# those partitions are gone and the warning would describe a disk that is empty.
wipe_fn=$(declare -f disk_execute_plan)
assert_true "auto-wipe clears BitLocker state" \
    grep -q 'BITLOCKER_DETECTED=0' <<< "${wipe_fn}"

# Case 9: hardware summary must not hide the warning behind APPLE_DETECTED —
# it first landed inside that block, so it showed up only on Macs, the one
# platform where BitLocker does not happen.
# Asserted on OUTPUT, not by parsing the function text: the nesting is the bug,
# and the only thing that proves it is fixed is that a non-Apple machine actually
# sees the line.
APPLE_DETECTED=0
BITLOCKER_DETECTED=1
BITLOCKER_PARTITIONS="/dev/nvme0n1p3"
# `set +u` inside the subshell: get_hardware_summary reads a long list of
# hardware variables that a unit test does not populate, and the suite runs
# with `set -u`. That is a property of the test harness, not of the code.
summary_out=$( set +u; get_hardware_summary 2>/dev/null || true )
assert_contains "warning shown on a non-Apple machine" "BitLocker" "${summary_out}"
assert_contains "...and names the partition" "/dev/nvme0n1p3" "${summary_out}"

BITLOCKER_DETECTED=0
BITLOCKER_PARTITIONS=""
summary_out=$( set +u; get_hardware_summary 2>/dev/null || true )
assert_true "no warning when nothing is encrypted" \
    test -z "$(grep -o 'BitLocker' <<< "${summary_out}" || true)"

# Case 10: the data-loss path. A BitLocker volume that lsblk reports as plain
# `ntfs` — the very case the signature check exists for — must never reach a
# resizer. Nothing in the shrink path looks at fstype alone any more.
SHRINK_PARTITION=/dev/nvme0n1p3
SHRINK_PARTITION_FSTYPE=ntfs
SHRINK_NEW_SIZE_MIB=100000
TARGET_DISK=/dev/nvme0n1
BITLOCKER_PARTITIONS="/dev/nvme0n1p3"
DISK_ACTIONS=()
rc=0
disk_plan_shrink >/dev/null 2>&1 || rc=$?
assert_eq "disk_plan_shrink refuses an encrypted volume reported as ntfs" "1" "${rc}"
assert_eq "...and plans nothing" "0" "${#DISK_ACTIONS[@]}"

# The same partition without BitLocker must still be plannable — the gate has to
# be about encryption, not about ntfs.
BITLOCKER_PARTITIONS=""
DISK_ACTIONS=()
disk_plan_shrink >/dev/null 2>&1 || true
assert_true "plain ntfs is still shrinkable" test "${#DISK_ACTIONS[@]}" -gt 0

# Case 5: wiring. Detection is worthless if the scan does not call it, and the
# probe loop must skip those partitions — an encrypted volume cannot be mounted,
# so probing it only produces noise.
scan_fn=$(declare -f detect_installed_oses)
assert_true "detect_installed_oses runs BitLocker detection" \
    grep -q 'detect_bitlocker' <<< "${scan_fn}"
assert_true "probe loop skips already-flagged BitLocker partitions" \
    grep -q 'BITLOCKER_PARTITIONS' <<< "${scan_fn}"
bl_line=$(grep -n 'detect_bitlocker' <<< "${scan_fn}" | head -1 | cut -d: -f1)
loop_line=$(grep -n 'while IFS' <<< "${scan_fn}" | head -1 | cut -d: -f1)
assert_true "detection runs BEFORE the probe loop" test "${bl_line}" -lt "${loop_line}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
