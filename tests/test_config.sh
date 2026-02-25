#!/usr/bin/env bash
# tests/test_config.sh — Test config save/load round-trip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Setup mock environment
export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-config.log"
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

echo "=== Test: Config Round-Trip ==="

# Set some config values
FILESYSTEM="btrfs"
HOSTNAME="test-host"
LOCALE="pl_PL.UTF-8"
BTRFS_SUBVOLUMES="@:/:@home:/home:@var-log:/var/log"
SWAP_TYPE="zram"
EXTRA_PACKAGES="vim git"
ENABLE_NONFREE="yes"
export FILESYSTEM HOSTNAME LOCALE BTRFS_SUBVOLUMES SWAP_TYPE EXTRA_PACKAGES ENABLE_NONFREE

# Save
TMPFILE="/tmp/void-test-config-$$.conf"
config_save "${TMPFILE}"

# Clear values
unset FILESYSTEM HOSTNAME LOCALE BTRFS_SUBVOLUMES SWAP_TYPE EXTRA_PACKAGES ENABLE_NONFREE

# Load
config_load "${TMPFILE}"

# Verify
assert_eq "FILESYSTEM" "btrfs" "${FILESYSTEM:-}"
assert_eq "HOSTNAME" "test-host" "${HOSTNAME:-}"
assert_eq "LOCALE" "pl_PL.UTF-8" "${LOCALE:-}"
assert_eq "BTRFS_SUBVOLUMES" "@:/:@home:/home:@var-log:/var/log" "${BTRFS_SUBVOLUMES:-}"
assert_eq "SWAP_TYPE" "zram" "${SWAP_TYPE:-}"
assert_eq "EXTRA_PACKAGES" "vim git" "${EXTRA_PACKAGES:-}"
assert_eq "ENABLE_NONFREE" "yes" "${ENABLE_NONFREE:-}"

# Test config_set / config_get
echo ""
echo "=== Test: config_set / config_get ==="
config_set "HOSTNAME" "new-host"
assert_eq "config_set HOSTNAME" "new-host" "$(config_get HOSTNAME)"

# Test special characters
config_set "EXTRA_PACKAGES" "pkg with spaces"
assert_eq "Spaces in value" "pkg with spaces" "$(config_get EXTRA_PACKAGES)"

config_set "BTRFS_SUBVOLUMES" '@:/:@home:/home'
assert_eq "Special chars (@/:)" "@:/:@home:/home" "$(config_get BTRFS_SUBVOLUMES)"

# Test round-trip with special characters
TMPFILE2="/tmp/void-test-config-special-$$.conf"
config_save "${TMPFILE2}"
unset HOSTNAME EXTRA_PACKAGES BTRFS_SUBVOLUMES
config_load "${TMPFILE2}"
assert_eq "Round-trip HOSTNAME" "new-host" "${HOSTNAME:-}"
assert_eq "Round-trip EXTRA_PACKAGES" "pkg with spaces" "${EXTRA_PACKAGES:-}"
assert_eq "Round-trip BTRFS_SUBVOLUMES" "@:/:@home:/home" "${BTRFS_SUBVOLUMES:-}"

# Cleanup
rm -f "${TMPFILE}" "${TMPFILE2}" "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
