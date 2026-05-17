#!/usr/bin/env bash
# tests/test_validate.sh — Test validate_config()
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Setup mock environment
export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-validate.log"
export DRY_RUN=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' not found in output"
        (( FAIL++ )) || true
    fi
}

# Helper: set all required vars to valid defaults (Void config schema)
set_valid_config() {
    export TARGET_DISK="/dev/sda"
    export PARTITION_SCHEME="auto"
    export FILESYSTEM="ext4"
    export SWAP_TYPE="zram"
    export HOSTNAME="voidbox"
    export TIMEZONE="Europe/Warsaw"
    export LOCALE="pl_PL.UTF-8"
    export KEYMAP="pl"
    export KERNEL_TYPE="mainline"
    export GPU_VENDOR="intel"
    export DESKTOP_TYPE="kde"
    export USERNAME="user"
    export ROOT_PASSWORD_HASH='$6$rounds=500000$salt$hash'
    export USER_PASSWORD_HASH='$6$rounds=500000$salt$hash'
}

clear_config() {
    unset TARGET_DISK PARTITION_SCHEME FILESYSTEM SWAP_TYPE \
          HOSTNAME TIMEZONE LOCALE KEYMAP KERNEL_TYPE GPU_VENDOR DESKTOP_TYPE USERNAME \
          ROOT_PASSWORD_HASH USER_PASSWORD_HASH ESP_PARTITION ROOT_PARTITION \
          ESP_REUSE SWAP_SIZE_MIB HYBRID_GPU MIRROR_URL 2>/dev/null || true
}

# ============================
echo "=== Test: Valid full config ==="
clear_config
set_valid_config

rc=0
output=$(validate_config) || rc=$?
assert_eq "Valid config returns 0" "0" "${rc}"
assert_eq "Valid config has no output" "" "${output}"

# ============================
echo ""
echo "=== Test: Missing required variables ==="
clear_config
set_valid_config
unset TARGET_DISK

rc=0
output=$(validate_config) || rc=$?
assert_eq "Missing TARGET_DISK returns 1" "1" "${rc}"
assert_contains "Output mentions TARGET_DISK" "TARGET_DISK" "${output}"

clear_config
set_valid_config
unset ROOT_PASSWORD_HASH

rc=0
output=$(validate_config) || rc=$?
assert_eq "Missing ROOT_PASSWORD_HASH returns 1" "1" "${rc}"
assert_contains "Output mentions ROOT_PASSWORD_HASH" "ROOT_PASSWORD_HASH" "${output}"

# ============================
echo ""
echo "=== Test: Invalid enum values ==="
clear_config
set_valid_config
export FILESYSTEM="zfs"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad FILESYSTEM returns 1" "1" "${rc}"
assert_contains "Output mentions FILESYSTEM" "FILESYSTEM" "${output}"

clear_config
set_valid_config
export KERNEL_TYPE="custom"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad KERNEL_TYPE returns 1" "1" "${rc}"
assert_contains "Output mentions KERNEL_TYPE" "KERNEL_TYPE" "${output}"

clear_config
set_valid_config
export KERNEL_TYPE="surface-patched"

rc=0
output=$(validate_config) || rc=$?
assert_eq "KERNEL_TYPE=surface-patched is valid" "0" "${rc}"

clear_config
set_valid_config
export GPU_VENDOR="radeon"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad GPU_VENDOR returns 1" "1" "${rc}"
assert_contains "Output mentions GPU_VENDOR" "GPU_VENDOR" "${output}"

clear_config
set_valid_config
export DESKTOP_TYPE="xfce"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad DESKTOP_TYPE returns 1" "1" "${rc}"
assert_contains "Output mentions DESKTOP_TYPE" "DESKTOP_TYPE" "${output}"

clear_config
set_valid_config
export DESKTOP_TYPE="gnome"

rc=0
output=$(validate_config) || rc=$?
assert_eq "DESKTOP_TYPE=gnome is valid" "0" "${rc}"

# ============================
echo ""
echo "=== Test: Hostname validation ==="
clear_config
set_valid_config
export HOSTNAME="-bad"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Hostname starting with hyphen returns 1" "1" "${rc}"
assert_contains "Output mentions HOSTNAME" "HOSTNAME" "${output}"

clear_config
set_valid_config
export HOSTNAME="ok-host"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Valid hyphenated hostname returns 0" "0" "${rc}"

# ============================
echo ""
echo "=== Test: Locale format ==="
clear_config
set_valid_config
export LOCALE="plPL.UTF-8"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad locale format returns 1" "1" "${rc}"
assert_contains "Output mentions LOCALE" "LOCALE" "${output}"

clear_config
set_valid_config
export LOCALE="en_US.utf8"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Locale without UTF-8 returns 1" "1" "${rc}"

# ============================
echo ""
echo "=== Test: MIRROR_URL must be http(s):// ==="
clear_config
set_valid_config
export MIRROR_URL="ftp://mirror.example.org/void"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Non-http(s) mirror returns 1" "1" "${rc}"
assert_contains "Output mentions MIRROR_URL" "MIRROR_URL" "${output}"

clear_config
set_valid_config
export MIRROR_URL="https://repo-default.voidlinux.org"

rc=0
output=$(validate_config) || rc=$?
assert_eq "https mirror is valid" "0" "${rc}"

clear_config
set_valid_config
export MIRROR_URL="http://mirror.example.org/void"

rc=0
output=$(validate_config) || rc=$?
assert_eq "http mirror is accepted (auto-upgraded at runtime)" "0" "${rc}"

# ============================
echo ""
echo "=== Test: Cross-field — SWAP_TYPE=file ==="
clear_config
set_valid_config
export SWAP_TYPE="file"
unset SWAP_SIZE_MIB 2>/dev/null || true

rc=0
output=$(validate_config) || rc=$?
assert_eq "File swap without size returns 1" "1" "${rc}"
assert_contains "Output mentions SWAP_SIZE_MIB" "SWAP_SIZE_MIB" "${output}"

clear_config
set_valid_config
export SWAP_TYPE="file"
export SWAP_SIZE_MIB="4096"

rc=0
output=$(validate_config) || rc=$?
assert_eq "File swap with size returns 0" "0" "${rc}"

# ============================
echo ""
echo "=== Test: Cross-field — dual-boot requires ESP ==="
clear_config
set_valid_config
export PARTITION_SCHEME="dual-boot"
unset ESP_PARTITION 2>/dev/null || true

rc=0
output=$(validate_config) || rc=$?
assert_eq "Dual-boot without ESP returns 1" "1" "${rc}"
assert_contains "Output mentions ESP_PARTITION" "ESP_PARTITION" "${output}"

clear_config
set_valid_config
export PARTITION_SCHEME="dual-boot"
export ESP_PARTITION="/dev/sda1"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Dual-boot with ESP returns 0" "0" "${rc}"

# ============================
echo ""
echo "=== Test: Cross-field — Secure Boot requires ESP ==="
clear_config
set_valid_config
export ENABLE_SECUREBOOT="yes"
unset ESP_PARTITION 2>/dev/null || true

rc=0
output=$(validate_config) || rc=$?
assert_eq "ENABLE_SECUREBOOT without ESP returns 1" "1" "${rc}"
assert_contains "Output mentions ESP_PARTITION" "ESP_PARTITION" "${output}"
unset ENABLE_SECUREBOOT 2>/dev/null || true

# ============================
echo ""
echo "=== Test: Multiple errors at once ==="
clear_config
set_valid_config
unset TARGET_DISK
export FILESYSTEM="zfs"
export HOSTNAME="-bad"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Multiple errors returns 1" "1" "${rc}"
assert_contains "Multi: mentions TARGET_DISK" "TARGET_DISK" "${output}"
assert_contains "Multi: mentions FILESYSTEM" "FILESYSTEM" "${output}"
assert_contains "Multi: mentions HOSTNAME" "HOSTNAME" "${output}"

# ============================
echo ""
echo "=== Test: DRY_RUN skips block device checks ==="
clear_config
set_valid_config
export DRY_RUN=1
export TARGET_DISK="/dev/nonexistent"

rc=0
output=$(validate_config) || rc=$?
assert_eq "DRY_RUN=1 skips block device check" "0" "${rc}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
