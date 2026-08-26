#!/usr/bin/env bash
# tests/test_wayland.sh — Wayland-only mode.
#
# The claim "no X server" is only true if the right packages are swapped AND
# the display manager is handled: GDM depends on the full xorg-server, so a
# Wayland-only GNOME that kept GDM would silently ship Xorg anyway. These
# assertions pin down that logic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-wayland.log"
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
source "${LIB_DIR}/desktop.sh"

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

assert_true() {
    local desc="$1"; shift
    if "$@"; then echo "  PASS: ${desc}"; (( PASS++ )) || true
    else echo "  FAIL: ${desc}"; (( FAIL++ )) || true; fi
}

assert_false() {
    local desc="$1"; shift
    if "$@"; then echo "  FAIL: ${desc}"; (( FAIL++ )) || true
    else echo "  PASS: ${desc}"; (( PASS++ )) || true; fi
}

echo "=== greetd session mapping ==="

assert_eq "gnome-wayland -> gnome-session"  "gnome-session"       "$(_greetd_session_command gnome-wayland)"
assert_eq "gnome -> gnome-session"          "gnome-session"       "$(_greetd_session_command gnome)"
assert_eq "niri -> niri-session"            "niri-session"        "$(_greetd_session_command niri)"
assert_eq "sway -> sway"                    "sway"                "$(_greetd_session_command sway)"
assert_eq "plasma -> startplasma-wayland"   "startplasma-wayland" "$(_greetd_session_command plasma)"
assert_eq "unknown falls through verbatim"  "hyprland"            "$(_greetd_session_command hyprland)"
assert_eq "empty falls back to gnome"       "gnome-session"       "$(_greetd_session_command '')"

echo ""
echo "=== KDE: Xwayland instead of the full X server ==="

kde_fn=$(declare -f _install_kde_plasma)
assert_true  "Wayland-only branch installs xorg-server-xwayland" \
    grep -q "x_pkgs=(xorg-server-xwayland)" <<< "${kde_fn}"
assert_true  "default branch still installs xorg-minimal" \
    grep -q "x_pkgs=(xorg-minimal)" <<< "${kde_fn}"
assert_true  "SDDM greeter is switched to Wayland" \
    grep -q "DisplayServer=wayland" <<< "${kde_fn}"
assert_true  "compositor for the greeter is kwin_wayland" \
    grep -q "CompositorCommand=kwin_wayland" <<< "${kde_fn}"

echo ""
echo "=== GNOME: GDM cannot stay (it depends on xorg-server) ==="

gnome_fn=$(declare -f _install_gnome_desktop)
assert_true  "Wayland-only branch installs greetd" \
    grep -q "greetd" <<< "${gnome_fn}"
assert_true  "Wayland-only branch installs tuigreet" \
    grep -q "tuigreet" <<< "${gnome_fn}"
assert_true  "Wayland-only branch pulls Xwayland for X11 apps" \
    grep -q "xorg-server-xwayland" <<< "${gnome_fn}"

# The gdm service must be enabled only on the non-Wayland-only path.
assert_true "greetd service enabled under Wayland-only" \
    grep -q '_enable_service "greetd"' <<< "${gnome_fn}"
assert_true "gdm service still enabled otherwise" \
    grep -q '_enable_service "gdm"' <<< "${gnome_fn}"

echo ""
echo "=== greetd config ==="

greetd_fn=$(declare -f _configure_greetd)
assert_true "config lists Wayland sessions" \
    grep -q "/usr/share/wayland-sessions" <<< "${greetd_fn}"
assert_true "greeter runs as the unprivileged _greeter user" \
    grep -q 'user = "_greeter"' <<< "${greetd_fn}"

echo ""
echo "=== Verification is real, not assumed ==="

verify_fn=$(declare -f verify_wayland_only)
assert_true "checks whether xorg-server is actually installed" \
    grep -q "xbps-query xorg-server" <<< "${verify_fn}"
assert_true "tells the user how to find the culprit" \
    grep -q "xbps-query -X xorg-server" <<< "${verify_fn}"

# No-op when the mode is off — must not warn on a normal install.
WAYLAND_ONLY="no"
out=$(verify_wayland_only 2>&1) || true
assert_eq "silent when Wayland-only is off" "" "${out}"

echo ""
echo "=== Validation and plumbing ==="

_valid_base() {
    TARGET_DISK="/dev/sda"; PARTITION_SCHEME="auto"; FILESYSTEM="ext4"
    SWAP_TYPE="zram"; HOSTNAME="void"; TIMEZONE="Europe/Warsaw"
    LOCALE="en_US.UTF-8"; KEYMAP="us"; KERNEL_TYPE="mainline"
    GPU_VENDOR="intel"; DESKTOP_TYPE="kde"; USERNAME="user"
    ROOT_PASSWORD_HASH='$6$x$y'; USER_PASSWORD_HASH='$6$x$y'
    ESP_PARTITION="/dev/sda1"; ROOT_PARTITION="/dev/sda2"
    LUKS_ENABLED="no"; WAYLAND_ONLY="no"
}

_valid_base
WAYLAND_ONLY="sometimes"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "bad WAYLAND_ONLY rejected" "1" "${rc}"

_valid_base
WAYLAND_ONLY="yes"
validate_config >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "WAYLAND_ONLY=yes is valid" "0" "${rc}"

found=0
for known in "${CONFIG_VARS[@]}"; do
    [[ "${known}" == "WAYLAND_ONLY" ]] && found=1 && break
done
assert_eq "WAYLAND_ONLY is in CONFIG_VARS" "1" "${found}"

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
