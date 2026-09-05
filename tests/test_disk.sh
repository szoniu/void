#!/usr/bin/env bash
# tests/test_disk.sh — Test disk operations in dry-run mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-disk.log"
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

assert_true() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc}"
        (( FAIL++ )) || true
    fi
}

assert_false() {
    local desc="$1"; shift
    if "$@"; then
        echo "  FAIL: ${desc}"
        (( FAIL++ )) || true
    else
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
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

echo "=== Test: Disk Plan Generation (auto, ext4) ==="

TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
SWAP_TYPE="zram"
PARTITION_SCHEME="auto"

disk_plan_auto

assert_eq "Plan has actions" "true" "$([[ ${#DISK_ACTIONS[@]} -gt 0 ]] && echo true || echo false)"
assert_eq "ESP partition set" "/dev/sda1" "${ESP_PARTITION}"
assert_eq "Root partition set" "/dev/sda2" "${ROOT_PARTITION}"

# sfdisk: 1 sfdisk + 2 mkfs = 3 actions (no swap)
assert_eq "Action count (auto, ext4, no swap)" "3" "${#DISK_ACTIONS[@]}"

# Verify plan contains expected operations
plan_text=""
for action in "${DISK_ACTIONS[@]}"; do
    plan_text+="${action%%|||*} "
done
assert_contains "Plan has GPT" "GPT" "${plan_text}"
assert_contains "Plan has ESP" "ESP" "${plan_text}"
assert_contains "Plan has ext4" "ext4" "${plan_text}"

# Verify sfdisk stdin script
assert_contains "sfdisk script has EFI GUID" "${GPT_TYPE_EFI}" "${DISK_STDIN[0]}"
assert_contains "sfdisk script has Linux GUID" "${GPT_TYPE_LINUX}" "${DISK_STDIN[0]}"
assert_contains "sfdisk script has label: gpt" "label: gpt" "${DISK_STDIN[0]}"

echo ""
echo "=== Test: Disk Plan Generation (auto, btrfs, swap partition) ==="

disk_plan_reset
FILESYSTEM="btrfs"
SWAP_TYPE="partition"
SWAP_SIZE_MIB="4096"

disk_plan_auto

assert_eq "ESP partition" "/dev/sda1" "${ESP_PARTITION}"
assert_eq "Swap partition set" "/dev/sda2" "${SWAP_PARTITION:-}"
assert_eq "Root partition" "/dev/sda3" "${ROOT_PARTITION}"

# sfdisk: 1 sfdisk + 3 mkfs = 4 actions (with swap)
assert_eq "Action count (auto, btrfs, swap)" "4" "${#DISK_ACTIONS[@]}"

# Verify sfdisk stdin includes swap GUID
assert_contains "sfdisk script has Swap GUID" "${GPT_TYPE_SWAP}" "${DISK_STDIN[0]}"

echo ""
echo "=== Test: NVMe partition naming ==="

disk_plan_reset
TARGET_DISK="/dev/nvme0n1"
FILESYSTEM="ext4"
SWAP_TYPE="none"

disk_plan_auto

assert_eq "NVMe ESP" "/dev/nvme0n1p1" "${ESP_PARTITION}"
assert_eq "NVMe root" "/dev/nvme0n1p2" "${ROOT_PARTITION}"

echo ""
echo "=== Test: DISK_STDIN parallel array ==="

# Verify DISK_STDIN has same length as DISK_ACTIONS
assert_eq "DISK_STDIN length matches DISK_ACTIONS" "${#DISK_ACTIONS[@]}" "${#DISK_STDIN[@]}"

# First entry (sfdisk) has stdin, rest (mkfs) don't
assert_eq "sfdisk entry has stdin" "true" "$([[ -n "${DISK_STDIN[0]}" ]] && echo true || echo false)"
assert_eq "mkfs entry has no stdin" "true" "$([[ -z "${DISK_STDIN[1]}" ]] && echo true || echo false)"

echo ""
echo "=== Test: Dry-run execution ==="

# Should succeed without actually doing anything
disk_execute_plan
assert_eq "Dry-run succeeds" "0" "$?"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== wait_for_block_device: wait for udev instead of guessing (Forgejo #19) ==="

# A path that will never become a block device must fail — and fail within the
# timeout, not hang. The point of the helper is that the caller can abort.
start=$(date +%s)
rc=0
wait_for_block_device "/nonexistent/void-test-device" 2 || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "missing device reports failure" "1" "${rc}"
# Both bounds matter: too long is a hang, too short means the loop is not
# actually waiting — which is how the first version of this helper was broken
# (udevadm settle returned instantly and the timeout became decorative).
assert_true "actually waits for the timeout (took ${elapsed}s, expected >= 2)" \
    test "${elapsed}" -ge 2
assert_true "does not overshoot the timeout (took ${elapsed}s, budget 2s + slack)" \
    test "${elapsed}" -le 8

# An empty argument is a no-op, not a two-second stall: the caller passes
# optional partitions (SWAP, LUKS) that may simply not be part of the plan.
rc=0
wait_for_block_device "" || rc=$?
assert_eq "empty device is a no-op" "0" "${rc}"

# Positive case against a real node, when the machine running the tests has one.
real_dev=$(lsblk -dpno NAME 2>/dev/null | head -1 || true)
if [[ -n "${real_dev}" && -b "${real_dev}" ]]; then
    rc=0
    wait_for_block_device "${real_dev}" 2 || rc=$?
    assert_eq "existing device returns immediately (${real_dev})" "0" "${rc}"
else
    echo "  SKIP: no block device available to test the positive path"
fi

# Which partitions are actually waited for — asserted on BEHAVIOUR, not with a
# grep over `declare -f`. Review demonstrated the grep version passed after the
# loop was narrowed to the ESP alone, i.e. against the exact regression it
# guards: mkfs.ext4 or cryptsetup luksFormat hitting a node udev has not created.
_waited=()
wait_for_block_device() { _waited+=("$1"); [[ "$1" != "${_MISSING_DEV:-}" ]]; }
die() { echo "DIED: $*"; return 1; }

ESP_PARTITION=/dev/sda1
BOOT_PARTITION=/dev/sda2
ROOT_PARTITION=/dev/sda3
SWAP_PARTITION=/dev/sda4
LUKS_PARTITION=/dev/sda5
PARTITION_SCHEME=auto
_MISSING_DEV=""
_wait_for_planned_partitions >/dev/null 2>&1
assert_eq "waits for EVERY planned partition, not just the ESP" \
    "/dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4 /dev/sda5" "${_waited[*]}"

# An optional partition that is not part of the plan must not be waited on.
_waited=(); SWAP_PARTITION=""; LUKS_PARTITION=""
_wait_for_planned_partitions >/dev/null 2>&1
assert_eq "skips partitions the plan does not include" \
    "/dev/sda1 /dev/sda2 /dev/sda3" "${_waited[*]}"

# A node that never appears must abort — formatting a path that does not exist
# is worse than a failed install.
_waited=(); SWAP_PARTITION=/dev/sda4; LUKS_PARTITION=/dev/sda5
_MISSING_DEV=/dev/sda3
out=$(_wait_for_planned_partitions 2>&1) || true
assert_contains "missing node aborts via die" "DIED:" "${out}"

# ...except for the documented dual-boot case, where sfdisk --append may renumber
# and the rescan below handles it.
PARTITION_SCHEME=dual-boot
out=$(_wait_for_planned_partitions 2>&1) || true
assert_true "dual-boot root partition warns instead of dying" \
    test -z "$(grep -o 'DIED:' <<< "${out}" || true)"

# ...but a missing ESP is still fatal, even in dual-boot.
_MISSING_DEV=/dev/sda1
out=$(_wait_for_planned_partitions 2>&1) || true
assert_contains "dual-boot exception does NOT extend to the ESP" "DIED:" "${out}"

unset -f wait_for_block_device die
_MISSING_DEV=""

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
