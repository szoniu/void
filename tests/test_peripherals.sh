#!/usr/bin/env bash
# tests/test_peripherals.sh — Peripheral opt-ins: config plumbing, validation,
# and recovery from an installed system on --resume (Forgejo #4).
#
# The failure this guards against is quiet: hardware is detected, but the
# ENABLE_* flag defaults to "no", so the phase that installs fprintd/bolt/
# iio-sensor-proxy/ModemManager does nothing and the finished system simply
# lacks what the user asked for — with no error anywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-peripherals.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

TEST_TMPDIR="$(mktemp -d)"
export CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints"
export CONFIG_FILE="${TEST_TMPDIR}/void-installer.conf"
export MOUNTPOINT="${TEST_TMPDIR}/mnt"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${DATA_DIR}/gpu_database.sh"
source "${LIB_DIR}/hardware.sh"

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

echo "=== Peripheral variables survive config save/load ==="

# The chroot phase is a separate process reading the saved config: a variable
# missing from CONFIG_VARS is a variable the second half of the install
# never sees.
for var in BLUETOOTH_DETECTED FINGERPRINT_DETECTED ENABLE_FINGERPRINT \
           THUNDERBOLT_DETECTED ENABLE_THUNDERBOLT SENSORS_DETECTED \
           ENABLE_SENSORS WEBCAM_DETECTED WWAN_DETECTED ENABLE_WWAN \
           ENABLE_IPTSD ENABLE_ASUSCTL; do
    found=0
    for known in "${CONFIG_VARS[@]}"; do
        [[ "${known}" == "${var}" ]] && found=1 && break
    done
    assert_eq "${var} in CONFIG_VARS" "1" "${found}"
done

TARGET_DISK="/dev/sda"; PARTITION_SCHEME="auto"; FILESYSTEM="ext4"
HOSTNAME="void"; USERNAME="user"
BLUETOOTH_DETECTED=1
FINGERPRINT_DETECTED=1; ENABLE_FINGERPRINT="yes"
THUNDERBOLT_DETECTED=1; ENABLE_THUNDERBOLT="yes"
SENSORS_DETECTED=1;     ENABLE_SENSORS="yes"
WEBCAM_DETECTED=1
WWAN_DETECTED=1;        ENABLE_WWAN="yes"
ENABLE_IPTSD="yes"
ENABLE_ASUSCTL="no"

config_save "${CONFIG_FILE}"

ENABLE_FINGERPRINT=""; ENABLE_THUNDERBOLT=""; ENABLE_SENSORS=""
ENABLE_WWAN=""; ENABLE_IPTSD=""; BLUETOOTH_DETECTED=""
config_load "${CONFIG_FILE}"

assert_eq "ENABLE_FINGERPRINT round-trip" "yes" "${ENABLE_FINGERPRINT}"
assert_eq "ENABLE_THUNDERBOLT round-trip" "yes" "${ENABLE_THUNDERBOLT}"
assert_eq "ENABLE_SENSORS round-trip"     "yes" "${ENABLE_SENSORS}"
assert_eq "ENABLE_WWAN round-trip"        "yes" "${ENABLE_WWAN}"
assert_eq "ENABLE_IPTSD round-trip"       "yes" "${ENABLE_IPTSD}"
assert_eq "BLUETOOTH_DETECTED round-trip" "1"   "${BLUETOOTH_DETECTED}"

echo ""
echo "=== Validation tolerates every peripheral flag ==="

TIMEZONE="Europe/Warsaw"; LOCALE="en_US.UTF-8"; KEYMAP="us"
KERNEL_TYPE="mainline"; GPU_VENDOR="intel"; DESKTOP_TYPE="kde"
SWAP_TYPE="zram"
ROOT_PASSWORD_HASH='$6$x$y'; USER_PASSWORD_HASH='$6$x$y'
ESP_PARTITION="/dev/sda1"; ROOT_PARTITION="/dev/sda2"
LUKS_ENABLED="no"; WAYLAND_ONLY="no"; ENABLE_SNAPPER="no"

validate_config >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "config with all peripherals enabled is valid" "0" "${rc}"

echo ""
echo "=== Recovery from an installed system (--resume without a config) ==="

_fake_system() {
    local root="$1"
    rm -rf "${root}"
    mkdir -p "${root}/etc" "${root}/usr/bin" "${root}/usr/sbin" \
             "${root}/usr/libexec" "${root}/var/service"
}

_clear_peripherals() {
    ENABLE_FINGERPRINT=""; FINGERPRINT_DETECTED=""
    ENABLE_THUNDERBOLT=""; THUNDERBOLT_DETECTED=""
    ENABLE_SENSORS="";     SENSORS_DETECTED=""
    ENABLE_WWAN="";        WWAN_DETECTED=""
    BLUETOOTH_DETECTED=""; ENABLE_SNAPPER=""; WAYLAND_ONLY=""
}

root="${TEST_TMPDIR}/target"

# 1. fingerprint via the binary
_fake_system "${root}"; _clear_peripherals
touch "${root}/usr/bin/fprintd-enroll"; chmod +x "${root}/usr/bin/fprintd-enroll"
_infer_peripherals_from_installed "${root}"
assert_eq "fprintd binary -> ENABLE_FINGERPRINT" "yes" "${ENABLE_FINGERPRINT}"
assert_eq "fprintd binary -> FINGERPRINT_DETECTED" "1" "${FINGERPRINT_DETECTED}"

# 2. thunderbolt via the enabled service (binary absent)
_fake_system "${root}"; _clear_peripherals
mkdir -p "${root}/var/service/bolt"
_infer_peripherals_from_installed "${root}"
assert_eq "bolt service -> ENABLE_THUNDERBOLT" "yes" "${ENABLE_THUNDERBOLT}"

# 3. sensors via libexec
_fake_system "${root}"; _clear_peripherals
touch "${root}/usr/libexec/iio-sensor-proxy"; chmod +x "${root}/usr/libexec/iio-sensor-proxy"
_infer_peripherals_from_installed "${root}"
assert_eq "iio-sensor-proxy -> ENABLE_SENSORS" "yes" "${ENABLE_SENSORS}"

# 4. WWAN via ModemManager
_fake_system "${root}"; _clear_peripherals
touch "${root}/usr/sbin/ModemManager"; chmod +x "${root}/usr/sbin/ModemManager"
_infer_peripherals_from_installed "${root}"
assert_eq "ModemManager -> ENABLE_WWAN" "yes" "${ENABLE_WWAN}"

# 5. bluetooth service
_fake_system "${root}"; _clear_peripherals
mkdir -p "${root}/var/service/bluetoothd"
_infer_peripherals_from_installed "${root}"
assert_eq "bluetoothd service -> BLUETOOTH_DETECTED" "1" "${BLUETOOTH_DETECTED}"

# 6. snapshots via the snapper config
_fake_system "${root}"; _clear_peripherals
mkdir -p "${root}/etc/snapper/configs"; touch "${root}/etc/snapper/configs/root"
_infer_peripherals_from_installed "${root}"
assert_eq "snapper config -> ENABLE_SNAPPER" "yes" "${ENABLE_SNAPPER}"

# 7. Wayland-only: greetd present AND no Xorg binary
_fake_system "${root}"; _clear_peripherals
mkdir -p "${root}/var/service/greetd"
_infer_peripherals_from_installed "${root}"
assert_eq "greetd without Xorg -> WAYLAND_ONLY" "yes" "${WAYLAND_ONLY}"

# ...but greetd next to an X server is NOT a Wayland-only system
_fake_system "${root}"; _clear_peripherals
mkdir -p "${root}/var/service/greetd"
touch "${root}/usr/bin/Xorg"; chmod +x "${root}/usr/bin/Xorg"
_infer_peripherals_from_installed "${root}"
assert_eq "greetd with Xorg -> not Wayland-only" "" "${WAYLAND_ONLY}"

# 8. a bare system enables nothing
_fake_system "${root}"; _clear_peripherals
_infer_peripherals_from_installed "${root}"
assert_eq "empty system: fingerprint off" "" "${ENABLE_FINGERPRINT}"
assert_eq "empty system: thunderbolt off" "" "${ENABLE_THUNDERBOLT}"
assert_eq "empty system: sensors off"     "" "${ENABLE_SENSORS}"
assert_eq "empty system: wwan off"        "" "${ENABLE_WWAN}"
assert_eq "empty system: bluetooth off"   "" "${BLUETOOTH_DETECTED}"
assert_eq "empty system: snapper off"     "" "${ENABLE_SNAPPER}"

# 9. everything at once
_fake_system "${root}"; _clear_peripherals
touch "${root}/usr/bin/fprintd-enroll" "${root}/usr/bin/boltctl" \
      "${root}/usr/libexec/iio-sensor-proxy" "${root}/usr/sbin/ModemManager"
chmod +x "${root}/usr/bin/fprintd-enroll" "${root}/usr/bin/boltctl" \
         "${root}/usr/libexec/iio-sensor-proxy" "${root}/usr/sbin/ModemManager"
mkdir -p "${root}/var/service/bluetoothd"
_infer_peripherals_from_installed "${root}"
assert_eq "all: fingerprint"  "yes" "${ENABLE_FINGERPRINT}"
assert_eq "all: thunderbolt"  "yes" "${ENABLE_THUNDERBOLT}"
assert_eq "all: sensors"      "yes" "${ENABLE_SENSORS}"
assert_eq "all: wwan"         "yes" "${ENABLE_WWAN}"
assert_eq "all: bluetooth"    "1"   "${BLUETOOTH_DETECTED}"

echo ""
echo "=== Detection helpers stay silent on absent hardware ==="

# These read /sys on the live machine; on a test box they must simply report
# nothing rather than fail (they run under `set -e` in detect_all_hardware).
detect_bluetooth   || true
detect_fingerprint || true
detect_thunderbolt || true
detect_sensors     || true
detect_webcam      || true
detect_wwan        || true

for var in BLUETOOTH_DETECTED FINGERPRINT_DETECTED THUNDERBOLT_DETECTED \
           SENSORS_DETECTED WEBCAM_DETECTED WWAN_DETECTED; do
    assert_eq "${var} is 0 or 1 after detection" "1" \
        "$( [[ "${!var}" == "0" || "${!var}" == "1" ]] && echo 1 || echo 0 )"
done

echo ""
echo "=== Flatpak: the remote is what makes it usable ==="

source "${LIB_DIR}/desktop.sh"

flat_fn=$(declare -f configure_flatpak)
assert_eq "runs only when flatpak was chosen" "1" \
    "$(grep -qc 'EXTRA_PACKAGES:-}" == \*flatpak\*' <<< "${flat_fn}" && echo 1 || echo 0)"
assert_eq "adds the Flathub remote" "1" \
    "$(grep -c 'flathub.flatpakrepo' <<< "${flat_fn}")"
assert_eq "remote-add is idempotent" "1" \
    "$(grep -qc -- '--if-not-exists' <<< "${flat_fn}" && echo 1 || echo 0)"
assert_eq "installs a portal implementation" "1" \
    "$(grep -qc 'xdg-desktop-portal' <<< "${flat_fn}" && echo 1 || echo 0)"

# The portal has to match the desktop, or dialogs look alien / do not work
assert_eq "GNOME gets the GNOME portal" "1" \
    "$(grep -qc 'xdg-desktop-portal-gnome' <<< "${flat_fn}" && echo 1 || echo 0)"
assert_eq "KDE gets the KDE portal" "1" \
    "$(grep -qc 'xdg-desktop-portal-kde' <<< "${flat_fn}" && echo 1 || echo 0)"

# Without this the apps install and then never show up in the menu
prof_fn=$(declare -f _flatpak_write_profile)
assert_eq "exports land on XDG_DATA_DIRS" "1" \
    "$(grep -qc '/var/lib/flatpak/exports/share' <<< "${prof_fn}" && echo 1 || echo 0)"
assert_eq "profile snippet is idempotent" "1" \
    "$(grep -qc 'exports/share:\"\*)' <<< "${prof_fn}" && echo 1 || echo 0)"

# No-op when the user did not pick flatpak
EXTRA_PACKAGES="btop fastfetch"
out=$(configure_flatpak 2>&1) || true
assert_eq "silent when flatpak was not selected" "" "${out}"

rm -rf "${TEST_TMPDIR}"
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
