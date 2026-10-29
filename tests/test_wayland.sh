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
assert_eq "mango -> dbus-run-session mango" "dbus-run-session mango" "$(_greetd_session_command mango)"
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

echo "=== Ekosystem mango ==="
mango_session_fn=$(declare -f _mango_write_session_file)
assert_true "sesja SDDM uruchamia mango z D-Bus" \
    grep -q 'Exec=dbus-run-session mango' <<< "${mango_session_fn}"
assert_true "sesja SDDM ma osobny plik" \
    grep -q '/usr/share/wayland-sessions/mango-dbus.desktop' <<< "${mango_session_fn}"
assert_true "instalacja mango zapisuje sesję SDDM" \
    grep -q '_mango_write_session_file' <<< "$(declare -f install_mango_ecosystem)"

_run_mango() (
    ENABLE_MANGO="$1"
    xbps-install() { printf 'xbps-install %s\n' "$*"; }
    _mango_write_session_file() { :; }
    install_mango_ecosystem
)
mango_out=$(_run_mango yes 2>&1)
assert_true "mango włączone: instalacja mangowc w dry-run" \
    grep -q 'Would execute: xbps-install -y mangowc' <<< "${mango_out}"
for pkg in xorg-server-xwayland foot rofi Waybar mako swaylock swayidle swaybg grim slurp wl-clipboard brightnessctl xdg-desktop-portal-wlr xdg-desktop-portal-gtk; do
    assert_true "mango włączone: pakiet ${pkg}" \
        grep -qx "xbps-install -y ${pkg}" <<< "${mango_out}"
done
assert_false "mango nie instaluje xwayland-satellite" \
    grep -q 'xwayland-satellite' <<< "${mango_out}"
assert_eq "mango wyłączone: brak instalacji" "" "$(_run_mango no 2>&1)"

echo "=== Ekran pakietów: mango ==="
source "${SCRIPT_DIR}/tui/extra_packages.sh"
# The checklist stub "returns" the given selection and records its arguments,
# so the screen's own parsing, resets and exports run unchanged.
_screen_with() (
    local wybor="$1"
    dialog_checklist() { printf '%s\n' "$@" > "${LOG_FILE}.args"; echo "${wybor}"; }
    dialog_inputbox() { echo ""; }
    screen_extra_packages > /dev/null 2>&1
    echo "mango=${ENABLE_MANGO} niri=${ENABLE_NIRI} extra=${EXTRA_PACKAGES}"
)
assert_eq "wybór mango włącza ENABLE_MANGO" "mango=yes niri=no extra=" \
    "$(ENABLE_MANGO=no ENABLE_NIRI=no _screen_with '"mango-ecosystem"')"
assert_eq "ponowny wybór bez mango i niri zeruje oba" "mango=no niri=no extra=btop" \
    "$(ENABLE_MANGO=yes ENABLE_NIRI=yes _screen_with '"btop"')"
ENABLE_MANGO=yes _screen_with '"mango-ecosystem"' > /dev/null
assert_eq "mango zaznaczone, gdy ENABLE_MANGO=yes" "on" \
    "$(grep -A2 -x 'mango-ecosystem' "${LOG_FILE}.args" | tail -1)"
rm -f "${LOG_FILE}.args"

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
