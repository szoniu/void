#!/usr/bin/env bash
# tests/test_snapper.sh — Btrfs snapshots (snapper + grub-btrfs) and the GRUB
# redirect stub that makes snapshot entries visible under Secure Boot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-snapper.log"
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
source "${LIB_DIR}/snapper.sh"
source "${LIB_DIR}/secureboot.sh"

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
        echo "  FAIL: ${desc} — '${needle}' not found"; (( FAIL++ )) || true
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' WAS found"; (( FAIL++ )) || true
    fi
}

assert_true() {
    local desc="$1"; shift
    if "$@"; then echo "  PASS: ${desc}"; (( PASS++ )) || true
    else echo "  FAIL: ${desc}"; (( FAIL++ )) || true; fi
}

echo "=== snapper config option editing ==="

tmpcfg=$(mktemp)
cat > "${tmpcfg}" << 'EOF'
TIMELINE_CREATE="no"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="10"
EOF

_snapper_set_option "${tmpcfg}" "TIMELINE_CREATE" "yes"
assert_contains "existing key is replaced" 'TIMELINE_CREATE="yes"' "$(cat "${tmpcfg}")"

# The anchored key must not let NUMBER_LIMIT clobber NUMBER_LIMIT_IMPORTANT
_snapper_set_option "${tmpcfg}" "NUMBER_LIMIT" "5"
assert_contains "NUMBER_LIMIT updated"              'NUMBER_LIMIT="5"'            "$(cat "${tmpcfg}")"
assert_contains "NUMBER_LIMIT_IMPORTANT untouched"  'NUMBER_LIMIT_IMPORTANT="10"' "$(cat "${tmpcfg}")"

_snapper_set_option "${tmpcfg}" "ALLOW_GROUPS" "wheel"
assert_contains "missing key is appended" 'ALLOW_GROUPS="wheel"' "$(cat "${tmpcfg}")"
rm -f "${tmpcfg}"

echo ""
echo "=== snapper_setup gating ==="

ENABLE_SNAPPER="no"
FILESYSTEM="btrfs"
out=$(snapper_setup 2>&1) || true
assert_eq "no-op when snapshots are off" "" "${out}"

ENABLE_SNAPPER="yes"
FILESYSTEM="ext4"
out=$(snapper_setup 2>&1) || true
assert_contains "refuses on a non-btrfs filesystem" "require btrfs" "${out}"

echo ""
echo "=== runit services, not systemd timers ==="

svc_fn=$(declare -f _snapper_enable_services)
assert_contains "snapperd enabled"   'snapperd'    "${svc_fn}"
assert_contains "grub-btrfs watcher enabled" 'grub-btrfs' "${svc_fn}"
assert_contains "cronie enabled (runs the timeline job)" 'cronie' "${svc_fn}"

cron_fn=$(declare -f _snapper_write_cron_jobs)
assert_contains "hourly timeline job"    "/etc/cron.hourly/snapper-timeline" "${cron_fn}"
assert_contains "daily cleanup job"      "/etc/cron.daily/snapper-cleanup"   "${cron_fn}"
assert_contains "snapper called without dbus in cron" "--no-dbus" "${cron_fn}"

echo ""
echo "=== XBPS has no transaction hooks — wrapper provides the equivalent ==="

wrap_fn=$(declare -f _snapper_install_update_wrapper)
assert_contains "wrapper installed as xbps-snapshot" "/usr/local/bin/xbps-snapshot" "${wrap_fn}"
assert_contains "takes a pre snapshot"  "--type pre"  "${wrap_fn}"
assert_contains "takes a post snapshot" "--type post" "${wrap_fn}"
assert_contains "post snapshot is linked to the pre one" "--pre-number" "${wrap_fn}"
assert_contains "transaction failure is reported, not swallowed" "transaction failed" "${wrap_fn}"

echo ""
echo "=== GRUB redirect stub (Secure Boot) ==="

# A full menu baked into the signed standalone freezes the boot menu: kernel
# updates and snapshot entries rewrite the EXTERNAL grub.cfg, which such an
# image never reads.
rebuild_fn=$(declare -f _rebuild_grub_with_sbat)
assert_contains "standalone embeds the stub"      'grub.cfg=${stub}' "${rebuild_fn}"
assert_not_contains "no full menu embedded" 'boot/grub/grub.cfg=/boot/grub/grub.cfg' "${rebuild_fn}"
assert_contains "cryptodisk modules available for LUKS" "cryptodisk" "${rebuild_fn}"

get_uuid() {
    case "$1" in
        /dev/mapper/cryptroot) echo "aaaa-bbbb-cccc" ;;
        /dev/sda2)             echo "1111-2222-3333" ;;
        *)                     echo "dead-beef" ;;
    esac
}

stub=$(mktemp)

# btrfs: root is on subvol @, GRUB sees the top-level tree
FILESYSTEM="btrfs"; LUKS_ENABLED="no"; ROOT_PARTITION="/dev/sda2"
_write_grub_redirect_stub "${stub}"
content=$(cat "${stub}")
assert_contains "btrfs stub points at /@/boot/grub" "/@/boot/grub" "${content}"
assert_contains "stub hands over with configfile"   "configfile"   "${content}"
assert_contains "stub sets prefix for module loading" "set prefix"  "${content}"

# ext4: plain path
FILESYSTEM="ext4"
_write_grub_redirect_stub "${stub}"
content=$(cat "${stub}")
assert_contains "ext4 stub points at /boot/grub" "set prefix=(\$root)/boot/grub" "${content}"
assert_not_contains "no subvolume path on ext4" "/@/boot" "${content}"

# LUKS: the container must be unlocked before the search
FILESYSTEM="btrfs"; LUKS_ENABLED="yes"; LUKS_PARTITION="/dev/sda2"
ROOT_PARTITION="/dev/mapper/cryptroot"
_write_grub_redirect_stub "${stub}"
content=$(cat "${stub}")
assert_contains "stub unlocks the container first" "cryptomount -u" "${content}"
assert_contains "cryptomount UUID has no dashes"   "111122223333"   "${content}"
assert_contains "search uses the mapper UUID"      "aaaa-bbbb-cccc" "${content}"
assert_eq "cryptomount comes before search" "1" \
    "$(awk '/cryptomount/{c=NR} /search/{s=NR} END{print (c && s && c < s) ? 1 : 0}' "${stub}")"

rm -f "${stub}"
unset -f get_uuid

echo ""
echo "=== Validation and plumbing ==="

_valid_base() {
    TARGET_DISK="/dev/sda"; PARTITION_SCHEME="auto"; FILESYSTEM="btrfs"
    SWAP_TYPE="zram"; HOSTNAME="void"; TIMEZONE="Europe/Warsaw"
    LOCALE="en_US.UTF-8"; KEYMAP="us"; KERNEL_TYPE="mainline"
    GPU_VENDOR="intel"; DESKTOP_TYPE="kde"; USERNAME="user"
    ROOT_PASSWORD_HASH='$6$x$y'; USER_PASSWORD_HASH='$6$x$y'
    ESP_PARTITION="/dev/sda1"; ROOT_PARTITION="/dev/sda2"
    LUKS_ENABLED="no"; WAYLAND_ONLY="no"; ENABLE_SNAPPER="no"
}

_valid_base
ENABLE_SNAPPER="perhaps"
validate_config >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "bad ENABLE_SNAPPER rejected" "1" "${rc}"

_valid_base
ENABLE_SNAPPER="yes"
FILESYSTEM="ext4"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "snapshots on ext4 rejected" "1" "${rc}"
assert_contains "message names btrfs" "btrfs" "${out}"

_valid_base
ENABLE_SNAPPER="yes"
validate_config >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "snapshots on btrfs accepted" "0" "${rc}"

found=0
for known in "${CONFIG_VARS[@]}"; do
    [[ "${known}" == "ENABLE_SNAPPER" ]] && found=1 && break
done
assert_eq "ENABLE_SNAPPER is in CONFIG_VARS" "1" "${found}"

found=0
for cp in "${CHECKPOINTS[@]}"; do
    [[ "${cp}" == "snapshots" ]] && found=1 && break
done
assert_eq "snapshots checkpoint registered" "1" "${found}"

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
