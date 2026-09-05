#!/usr/bin/env bash
# tests/test_system.sh — lib/system.sh: service enablement, sudo configuration
# and the leftovers a chroot install leaves behind.
#
# Every assertion here guards a failure that is INVISIBLE at install time: the
# log says the service is on / sudo is configured / DNS is fine, and the machine
# proves otherwise after the first reboot. They run against real temp
# directories rather than greps, because the bugs were in the *effect* of the
# code, not in its text.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-system.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/system.sh"

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
    if "$@"; then
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    else
        echo "  FAIL: ${desc}"; (( FAIL++ )) || true
    fi
}

assert_false() {
    local desc="$1"; shift
    if "$@"; then
        echo "  FAIL: ${desc}"; (( FAIL++ )) || true
    else
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    fi
}

TMP_ROOT=$(mktemp -d /tmp/void-test-system.XXXXXX)
cleanup() { rm -rf "${TMP_ROOT}"; }
trap cleanup EXIT

echo "=== _enable_service: symlink is verified, not assumed ==="

# Case 1: /var/service resolves to a real directory — the normal path.
root1="${TMP_ROOT}/ok"
mkdir -p "${root1}/etc/sv/sddm" "${root1}/var/service"
SERVICE_ROOT="${root1}" _enable_service "sddm" >/dev/null 2>&1
assert_true "service linked into /var/service when it exists" \
    test -L "${root1}/var/service/sddm"

# Case 2: /var/service is a DANGLING symlink — exactly the chroot state before
# xbps-reconfigure runs runit-void's INSTALL script. The old code linked into
# the void and reported success.
root2="${TMP_ROOT}/dangling"
mkdir -p "${root2}/etc/sv/zramen" "${root2}/var"
ln -s "/etc/runit/runsvdir/current" "${root2}/var/service"
SERVICE_ROOT="${root2}" _enable_service "zramen" >/dev/null 2>&1
assert_true "falls back to /etc/runit/runsvdir/default when /var/service dangles" \
    test -L "${root2}/etc/runit/runsvdir/default/zramen"

# Case 3: non-critical service that cannot be linked must WARN and return 1,
# not report success. The target is made unwritable to force the failure.
root3="${TMP_ROOT}/readonly"
mkdir -p "${root3}/etc/sv/cupsd" "${root3}/var/service"
chmod 500 "${root3}/var/service"
rc=0
SERVICE_ROOT="${root3}" _enable_service "cupsd" >/dev/null 2>&1 || rc=$?
chmod 700 "${root3}/var/service"
assert_eq "unlinkable non-critical service returns failure" "1" "${rc}"

# Case 4: a missing /etc/sv entry is a failure too — it used to warn and then
# return the exit status of `ewarn`, i.e. success.
root4="${TMP_ROOT}/missing"
mkdir -p "${root4}/var/service"
rc=0
SERVICE_ROOT="${root4}" _enable_service "nosuchservice" >/dev/null 2>&1 || rc=$?
assert_eq "missing service definition returns failure" "1" "${rc}"

# Case 5: the critical list must abort instead of warning. Checked in a
# subshell, since the failure path calls die (exit 1).
root5="${TMP_ROOT}/critical"
mkdir -p "${root5}/etc/sv/udevd" "${root5}/var/service"
chmod 500 "${root5}/var/service"
rc=0
( SERVICE_ROOT="${root5}" _enable_service "udevd" ) >/dev/null 2>&1 || rc=$?
chmod 700 "${root5}/var/service"
assert_eq "unlinkable CRITICAL service aborts the install" "1" "${rc}"

# The list itself is part of the contract: these are the services whose absence
# leaves a machine with no console, no seat and no login.
for svc in udevd dbus elogind agetty-tty1 sddm; do
    assert_true "${svc} is on the critical list" \
        grep -q " ${svc} " <<< " ${_CRITICAL_SERVICES} "
done

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
