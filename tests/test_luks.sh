#!/usr/bin/env bash
# tests/test_luks.sh — LUKS planning, secret handling and system wiring.
# The passphrase must never reach the log or a command line; the container
# must never be re-formatted on a resume. Both are asserted here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-luks.log"
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
source "${LIB_DIR}/luks.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — expected '${expected}', got '${actual}'"; (( FAIL++ )) || true
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' not in output"; (( FAIL++ )) || true
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' WAS found (must not be)"; (( FAIL++ )) || true
    fi
}

# Common config for a plain auto-partition run
_setup_config() {
    TARGET_DISK="/dev/sda"
    FILESYSTEM="ext4"
    SWAP_TYPE="zram"
    PARTITION_SCHEME="auto"
    LUKS_ENABLED="yes"
    LUKS_NAME="cryptroot"
    _LUKS_PASSPHRASE="correct horse battery staple"
    ESP_PARTITION=""; ROOT_PARTITION=""; SWAP_PARTITION=""; LUKS_PARTITION=""
}

echo "=== Plan: LUKS sits between partitioning and mkfs ==="

# blkid stub: a fresh disk, no LUKS header yet
blkid() { return 1; }

DRY_RUN=0
_setup_config
disk_plan_auto

assert_eq "raw partition recorded as the container" "/dev/sda2" "${LUKS_PARTITION}"
assert_eq "root points at the mapper device" "/dev/mapper/cryptroot" "${ROOT_PARTITION}"

plan_text=$(printf '%s\n' "${DISK_ACTIONS[@]}")
assert_contains "plan formats the container"   "luksFormat" "${plan_text}"
assert_contains "plan opens the container"     "luksOpen"   "${plan_text}"
assert_contains "plan adds the initramfs keyfile" "luksAddKey" "${plan_text}"
assert_contains "mkfs targets the mapper"      "mkfs.ext4" "${plan_text}"

# Ordering matters: formatting the filesystem before opening the container
# would write ext4 over the LUKS header.
fmt_idx=-1; open_idx=-1; mkfs_idx=-1
for i in "${!DISK_ACTIONS[@]}"; do
    [[ "${DISK_ACTIONS[$i]}" == *luksFormat* && ${fmt_idx} -lt 0 ]] && fmt_idx=${i}
    [[ "${DISK_ACTIONS[$i]}" == *luksOpen* && ${open_idx} -lt 0 ]] && open_idx=${i}
    [[ "${DISK_ACTIONS[$i]}" == *mkfs.ext4* && ${mkfs_idx} -lt 0 ]] && mkfs_idx=${i}
done
assert_eq "luksFormat precedes luksOpen" "yes" "$( [[ ${fmt_idx} -lt ${open_idx} ]] && echo yes || echo no )"
assert_eq "luksOpen precedes mkfs"       "yes" "$( [[ ${open_idx} -lt ${mkfs_idx} ]] && echo yes || echo no )"

echo ""
echo "=== The passphrase never leaks ==="

# Every LUKS action must be flagged secret...
secret_count=0
for i in "${!DISK_STDIN[@]}"; do
    if [[ -n "${DISK_STDIN[$i]}" && "${DISK_SECRET[$i]:-0}" == "1" ]]; then
        (( secret_count++ )) || true
        assert_eq "secret payload $i is the passphrase" "correct horse battery staple" "${DISK_STDIN[$i]}"
    fi
done
assert_eq "three secret actions (format, open, addkey)" "3" "${secret_count}"

# ...and the sfdisk script must NOT be, or it would be masked pointlessly
assert_eq "sfdisk stdin is not marked secret" "0" "${DISK_SECRET[0]}"

# disk_plan_show writes to the log — the passphrase must not appear there
: > "${LOG_FILE}"
disk_plan_show >/dev/null 2>&1
log_text=$(cat "${LOG_FILE}")
assert_not_contains "passphrase absent from the log" "correct horse battery staple" "${log_text}"
assert_contains "log says the payload was withheld" "secret withheld" "${log_text}"

echo ""
echo "=== Resume: an existing container is opened, never re-formatted ==="

# blkid stub: partition already carries a LUKS header
blkid() { echo "crypto_LUKS"; return 0; }

_setup_config
disk_plan_auto
plan_text=$(printf '%s\n' "${DISK_ACTIONS[@]}")

assert_not_contains "no luksFormat on an existing container" "luksFormat" "${plan_text}"
assert_contains     "still opens the container"              "luksOpen"   "${plan_text}"
assert_not_contains "no extra key slot burned on resume"     "luksAddKey" "${plan_text}"

unset -f blkid
DRY_RUN=1

echo ""
echo "=== Dual-boot uses the same path ==="

blkid() { return 1; }
DRY_RUN=0
_setup_config
PARTITION_SCHEME="dual-boot"
ESP_PARTITION="/dev/sda1"
ROOT_PARTITION="/dev/sda3"
disk_plan_dualboot

assert_eq "dual-boot records the container partition" "/dev/sda3" "${LUKS_PARTITION}"
assert_eq "dual-boot root is the mapper" "/dev/mapper/cryptroot" "${ROOT_PARTITION}"
unset -f blkid
DRY_RUN=1

echo ""
echo "=== GRUB cmdline ==="

get_uuid() { echo "1234abcd-5678-90ef-1234-567890abcdef"; }
LUKS_ENABLED="yes"
LUKS_PARTITION="/dev/sda2"
LUKS_KEYFILE_TARGET="/nonexistent-keyfile"
cmdline=$(luks_grub_cmdline)
assert_contains "cmdline carries rd.luks.uuid" "rd.luks.uuid=1234abcd" "${cmdline}"
assert_not_contains "no rd.luks.key when the keyfile is absent" "rd.luks.key" "${cmdline}"

LUKS_ENABLED="no"
assert_eq "no cmdline when LUKS is off" "" "$(luks_grub_cmdline)"
unset -f get_uuid

echo ""
echo "=== Validation gates ==="

_valid_base() {
    TARGET_DISK="/dev/sda"; PARTITION_SCHEME="auto"; FILESYSTEM="ext4"
    SWAP_TYPE="zram"; HOSTNAME="void"; TIMEZONE="Europe/Warsaw"
    LOCALE="en_US.UTF-8"; KEYMAP="us"; KERNEL_TYPE="mainline"
    GPU_VENDOR="intel"; DESKTOP_TYPE="kde"; USERNAME="user"
    ROOT_PASSWORD_HASH='$6$x$y'; USER_PASSWORD_HASH='$6$x$y'
    ESP_PARTITION="/dev/sda1"; ROOT_PARTITION="/dev/sda2"
    LUKS_ENABLED="no"; LUKS_PARTITION=""
}

_valid_base
LUKS_ENABLED="maybe"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "bad LUKS_ENABLED rejected" "1" "${rc}"
assert_contains "message names LUKS_ENABLED" "LUKS_ENABLED" "${out}"

_valid_base
LUKS_ENABLED="yes"
LUKS_PARTITION=""
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "LUKS without a container partition rejected" "1" "${rc}"

_valid_base
LUKS_ENABLED="yes"
PARTITION_SCHEME="manual"
LUKS_PARTITION="/dev/sda2"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "LUKS + manual partitioning rejected" "1" "${rc}"
assert_contains "message explains manual is unsupported" "manual partitioning" "${out}"

echo ""
echo "=== Config plumbing ==="

for var in LUKS_ENABLED LUKS_PARTITION; do
    found=0
    for known in "${CONFIG_VARS[@]}"; do
        [[ "${known}" == "${var}" ]] && found=1 && break
    done
    assert_eq "${var} is in CONFIG_VARS" "1" "${found}"
done

# The passphrase must NOT be persisted — config_save would write it to disk.
found=0
for known in "${CONFIG_VARS[@]}"; do
    [[ "${known}" == *PASSPHRASE* ]] && found=1
done
assert_eq "no passphrase variable in CONFIG_VARS" "0" "${found}"

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
