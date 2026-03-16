#!/usr/bin/env bash
# tests/test_resume.sh — Test --resume disk scanning and recovery
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-resume.log"
export DRY_RUN=1
export NON_INTERACTIVE=1

# Use temp dirs for testing (avoid touching real system)
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

# --- Helper: create fake partition with checkpoints + config ---
setup_fake_partition() {
    local part_name="$1"
    local has_checkpoints="${2:-0}"
    local has_config="${3:-0}"

    local fake_mp="${_RESUME_TEST_DIR}/mnt/${part_name}"
    mkdir -p "${fake_mp}"

    if [[ ${has_checkpoints} -eq 1 ]]; then
        local cp_dir="${fake_mp}${CHECKPOINT_DIR_SUFFIX}"
        mkdir -p "${cp_dir}"
        touch "${cp_dir}/disks"
        touch "${cp_dir}/rootfs_extract"
        touch "${cp_dir}/xbps_preconfig"
    fi

    if [[ ${has_config} -eq 1 ]]; then
        mkdir -p "${fake_mp}/tmp"
        # Create a valid config file
        (
            umask 077
            cat > "${fake_mp}/tmp/void-installer.conf" <<'CONF'
#!/usr/bin/env bash
# Void TUI Installer configuration
TARGET_DISK='/dev/sda'
FILESYSTEM='ext4'
HOSTNAME='testhost'
CONF
        )
    fi
}

# ================================================================
echo "=== Test: _scan_partition_for_resume — partition with checkpoints + config ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
setup_fake_partition "sda2" 1 1
echo "/dev/sda2 ext4" > "${_RESUME_TEST_DIR}/partitions.list"

_scan_partition_for_resume "/dev/sda2" "ext4"
assert_eq "Checkpoints detected" "1" "${_SCAN_HAS_CHECKPOINTS}"
assert_eq "Config detected" "1" "${_SCAN_HAS_CONFIG}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: _scan_partition_for_resume — partition with checkpoints only ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
setup_fake_partition "sda2" 1 0
echo "/dev/sda2 ext4" > "${_RESUME_TEST_DIR}/partitions.list"

_scan_partition_for_resume "/dev/sda2" "ext4"
assert_eq "Checkpoints detected" "1" "${_SCAN_HAS_CHECKPOINTS}"
assert_eq "Config not detected" "0" "${_SCAN_HAS_CONFIG}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: _scan_partition_for_resume — empty partition ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
setup_fake_partition "sdb1" 0 0
echo "/dev/sdb1 ext4" > "${_RESUME_TEST_DIR}/partitions.list"

_scan_partition_for_resume "/dev/sdb1" "ext4"
assert_eq "No checkpoints on empty partition" "0" "${_SCAN_HAS_CHECKPOINTS}"
assert_eq "No config on empty partition" "0" "${_SCAN_HAS_CONFIG}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: try_resume_from_disk — returns 0 with config + checkpoints ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test1"
CONFIG_FILE="${TEST_TMPDIR}/config-test1.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

setup_fake_partition "nvme0n1p2" 1 1
echo "/dev/nvme0n1p2 ext4" > "${_RESUME_TEST_DIR}/partitions.list"

rc=0
try_resume_from_disk || rc=$?
assert_eq "Return code 0 (config + checkpoints)" "0" "${rc}"
assert_eq "RESUME_FOUND_PARTITION set" "/dev/nvme0n1p2" "${RESUME_FOUND_PARTITION}"
assert_eq "RESUME_HAS_CONFIG is 1" "1" "${RESUME_HAS_CONFIG}"
assert_eq "Checkpoint disks recovered" "true" "$([[ -f "${CHECKPOINT_DIR}/disks" ]] && echo true || echo false)"
assert_eq "Checkpoint rootfs_extract recovered" "true" "$([[ -f "${CHECKPOINT_DIR}/rootfs_extract" ]] && echo true || echo false)"
assert_eq "Config file recovered" "true" "$([[ -f "${CONFIG_FILE}" ]] && echo true || echo false)"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: try_resume_from_disk — returns 1 with checkpoints only ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test2"
CONFIG_FILE="${TEST_TMPDIR}/config-test2.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

setup_fake_partition "sda3" 1 0
echo "/dev/sda3 btrfs" > "${_RESUME_TEST_DIR}/partitions.list"

rc=0
try_resume_from_disk || rc=$?
assert_eq "Return code 1 (checkpoints only)" "1" "${rc}"
assert_eq "RESUME_FOUND_PARTITION set" "/dev/sda3" "${RESUME_FOUND_PARTITION}"
assert_eq "RESUME_HAS_CONFIG is 0" "0" "${RESUME_HAS_CONFIG}"
assert_eq "Checkpoints recovered" "true" "$([[ -f "${CHECKPOINT_DIR}/disks" ]] && echo true || echo false)"
assert_eq "No config file" "false" "$([[ -f "${CONFIG_FILE}" ]] && echo true || echo false)"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: try_resume_from_disk — returns 2 when nothing found ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test3"
CONFIG_FILE="${TEST_TMPDIR}/config-test3.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

setup_fake_partition "sda1" 0 0
echo "/dev/sda1 ext4" > "${_RESUME_TEST_DIR}/partitions.list"

rc=0
try_resume_from_disk || rc=$?
assert_eq "Return code 2 (nothing found)" "2" "${rc}"
assert_eq "RESUME_FOUND_PARTITION empty" "" "${RESUME_FOUND_PARTITION}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: try_resume_from_disk — skips unsupported fstypes ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test4"
CONFIG_FILE="${TEST_TMPDIR}/config-test4.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

# Only create checkpoints on swap partition (should be skipped)
setup_fake_partition "sda1" 1 1
echo "/dev/sda1 swap" > "${_RESUME_TEST_DIR}/partitions.list"

rc=0
try_resume_from_disk || rc=$?
assert_eq "Return code 2 (swap skipped)" "2" "${rc}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: try_resume_from_disk — scans multiple partitions ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test5"
CONFIG_FILE="${TEST_TMPDIR}/config-test5.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

setup_fake_partition "sda1" 0 0
setup_fake_partition "sda2" 1 1
cat > "${_RESUME_TEST_DIR}/partitions.list" <<'LIST'
/dev/sda1 ext4
/dev/sda2 ext4
LIST

rc=0
try_resume_from_disk || rc=$?
assert_eq "Return code 0 (found on second partition)" "0" "${rc}"
assert_eq "Found correct partition" "/dev/sda2" "${RESUME_FOUND_PARTITION}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: recovered config has restricted permissions ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test6"
CONFIG_FILE="${TEST_TMPDIR}/config-test6.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

setup_fake_partition "sda2" 1 1
echo "/dev/sda2 ext4" > "${_RESUME_TEST_DIR}/partitions.list"

try_resume_from_disk || true
# Linux uses -c '%a', macOS uses -f '%Lp'
perms=$(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || stat -f '%Lp' "${CONFIG_FILE}" 2>/dev/null || echo "000")
assert_eq "Config file permissions restricted (600)" "600" "${perms}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: recovered config is loadable ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test7"
CONFIG_FILE="${TEST_TMPDIR}/config-test7.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

setup_fake_partition "sda2" 1 1
echo "/dev/sda2 ext4" > "${_RESUME_TEST_DIR}/partitions.list"

try_resume_from_disk || true
config_load "${CONFIG_FILE}"
assert_eq "TARGET_DISK loaded from config" "/dev/sda" "${TARGET_DISK:-}"
assert_eq "HOSTNAME loaded from config" "testhost" "${HOSTNAME:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: try_resume_from_disk — btrfs partition works ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test8"
CONFIG_FILE="${TEST_TMPDIR}/config-test8.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

setup_fake_partition "sda2" 1 1
echo "/dev/sda2 btrfs" > "${_RESUME_TEST_DIR}/partitions.list"

rc=0
try_resume_from_disk || rc=$?
assert_eq "Return code 0 (btrfs partition)" "0" "${rc}"
assert_eq "RESUME_FOUND_PARTITION btrfs" "/dev/sda2" "${RESUME_FOUND_PARTITION}"
assert_eq "RESUME_HAS_CONFIG btrfs" "1" "${RESUME_HAS_CONFIG}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: try_resume_from_disk — xfs partition works ==="

export _RESUME_TEST_DIR="$(mktemp -d)"
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints-test9"
CONFIG_FILE="${TEST_TMPDIR}/config-test9.conf"
rm -rf "${CHECKPOINT_DIR}" "${CONFIG_FILE}"

setup_fake_partition "sdb1" 1 0
echo "/dev/sdb1 xfs" > "${_RESUME_TEST_DIR}/partitions.list"

rc=0
try_resume_from_disk || rc=$?
assert_eq "Return code 1 (xfs, checkpoints only)" "1" "${rc}"
assert_eq "RESUME_FOUND_PARTITION xfs" "/dev/sdb1" "${RESUME_FOUND_PARTITION}"

rm -rf "${_RESUME_TEST_DIR}"
unset _RESUME_TEST_DIR

# Cleanup
rm -rf "${TEST_TMPDIR}"
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
