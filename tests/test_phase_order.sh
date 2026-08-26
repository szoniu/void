#!/usr/bin/env bash
# tests/test_phase_order.sh — Structural guards for fixes whose failure mode is
# an unbootable or unloginnable system. Each one cost a real machine somewhere
# (Gentoo installer incidents), so they are asserted rather than trusted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"

PASS=0
FAIL=0

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

# _line_of — first line number matching a pattern in a file
_line_of() {
    grep -n "$2" "${SCRIPT_DIR}/$1" | head -1 | cut -d: -f1
}

echo "=== Users are created before kernel/desktop ==="

users_line=$(_line_of install.sh 'system_create_users')
kernel_line=$(_line_of install.sh '^        kernel_install')
desktop_line=$(_line_of install.sh '^        desktop_install')

assert_true "users phase precedes kernel"  test "${users_line}" -lt "${kernel_line}"
assert_true "users phase precedes desktop" test "${users_line}" -lt "${desktop_line}"

echo ""
echo "=== Empty root password hash is not silent ==="

assert_true "system_create_users warns when ROOT_PASSWORD_HASH is empty" \
    grep -q "ROOT_PASSWORD_HASH is empty" "${SCRIPT_DIR}/lib/system.sh"

echo ""
echo "=== Resume never blind-reformats a disk holding a system ==="

assert_true "_resume_target_has_system exists" \
    grep -q "^_resume_target_has_system()" "${SCRIPT_DIR}/lib/utils.sh"
assert_true "disks phase consults it" \
    grep -q "_resume_target_has_system" "${SCRIPT_DIR}/tui/progress.sh"
assert_true "probe mounts read-only" \
    grep -q 'mount -o "${opt}"' "${SCRIPT_DIR}/lib/utils.sh"
assert_true "probe tries subvol=@ first" \
    grep -q '"ro,subvol=@" "ro"' "${SCRIPT_DIR}/lib/utils.sh"

echo ""
echo "=== btrfs subvolumes mount on the resume path too ==="

# The @home mount must NOT sit inside the "root was not yet mounted" branch:
# a resumed users phase with @home unmounted writes the home directory into @,
# and fstab then hides it at boot (login fails).
assert_true "mount_filesystems guards each mount with mountpoint -q" \
    grep -q 'if ! mountpoint -q "${MOUNTPOINT}${mpoint}"' "${SCRIPT_DIR}/lib/disk.sh"
assert_true "ESP mount is idempotent" \
    grep -q 'if ! mountpoint -q "${esp_mount}"' "${SCRIPT_DIR}/lib/disk.sh"

echo ""
echo "=== btrfs rootflags are not duplicated on the cmdline ==="

assert_false "GRUB_CMDLINE_LINUX does not hardcode rootflags" \
    grep -q 'extra_params="rootflags=subvol=@"' "${SCRIPT_DIR}/lib/bootloader.sh"
assert_true "safety net re-adds it only when grub-mkconfig did not" \
    grep -q "grub-mkconfig did not add rootflags" "${SCRIPT_DIR}/lib/bootloader.sh"

echo ""
echo "=== Apple boots from the removable path ==="

assert_true "grub-install --removable is used on Apple" \
    grep -q -- "--removable --recheck" "${SCRIPT_DIR}/lib/bootloader.sh"
assert_true "NVRAM entry on Apple is best-effort, not a try() failure" \
    grep -q 'recheck &>/dev/null || true' "${SCRIPT_DIR}/lib/bootloader.sh"

echo ""
echo "=== Skipped steps and logs survive ==="

assert_true "try() records skipped steps" \
    grep -q 'SKIPPED_LOG' "${SCRIPT_DIR}/lib/utils.sh"
assert_true "chroot phase logs to /var/log" \
    grep -q '/var/log/void-installer.log' "${SCRIPT_DIR}/install.sh"
assert_true "post-install surfaces skipped steps" \
    grep -q "Installation Incomplete" "${SCRIPT_DIR}/install.sh"

echo ""
echo "=== GPU classification is vendor-based, not PCI-bus-based ==="

assert_false "no 'bus 00 = iGPU' heuristic left" \
    grep -q 'slot_bus}" == "00"' "${SCRIPT_DIR}/lib/hardware.sh"
assert_true "AMD is classified from the vendor set" \
    grep -q "amd_idxs" "${SCRIPT_DIR}/lib/hardware.sh"

echo ""
echo "=== Void package names that silently resolve to nothing ==="

# The Void package is `Waybar` (capital W); `waybar` resolves to nothing and
# xbps just skips it. The binary it installs is lowercase, so only package
# lists are checked here — not the compositor configs that spawn it.
assert_false "no lowercase 'waybar' in package lists" \
    grep -qE "^\s+(waybar|xbps-install -y waybar)\b" "${SCRIPT_DIR}/lib/desktop.sh"
assert_true "package lists use 'Waybar'" \
    grep -q "Waybar" "${SCRIPT_DIR}/lib/desktop.sh"
assert_false "dead noctalia repo is not written" \
    grep -q 'echo "repository=https://rxelelo' "${SCRIPT_DIR}/lib/desktop.sh"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
