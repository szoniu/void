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
source "${LIB_DIR}/chroot.sh"
source "${LIB_DIR}/snapper.sh"
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
# The link target must be resolved INSIDE the fake root, not against the host:
# on an actual Void box /etc/runit/runsvdir/current exists, the fallback branch
# would never run and this assertion would silently invert — on the one platform
# where anyone would really verify this code.
ln -s "${root2}/etc/runit/runsvdir/current" "${root2}/var/service"
SERVICE_ROOT="${root2}" _enable_service "zramen" >/dev/null 2>&1
assert_true "falls back to /etc/runit/runsvdir/default when /var/service dangles" \
    test -L "${root2}/etc/runit/runsvdir/default/zramen"

# The next three cases assert on the EFFECT, not on the exit code. Both matter,
# and the exit code alone cannot tell them apart: `die` exits 1 and a plain
# `return 1` is also 1, so an assertion on rc passed unchanged even when the
# whole critical-service abort was deleted from the function (verified by
# mutation — the suite still reported 21/21).
#
# It is also the wrong contract to assert. install.sh runs under
# `set -Eeuo pipefail` and every call site is a bare command, so returning 1 for
# a missing service would abort the installer mid-chroot. Non-critical failures
# therefore return 0 BY DESIGN and report through SKIPPED_LOG.

# _reaches_next_statement — did control flow continue past the call?
# Echoes REACHED only if the function returned instead of aborting.
_reaches_next_statement() {
    local out
    out=$( ( SERVICE_ROOT="$1" SKIPPED_LOG="${TMP_ROOT}/skipped.log" \
             _enable_service "$2" >/dev/null 2>&1; echo REACHED ) 2>&1 )
    [[ "${out}" == *REACHED* ]]
}

# Case 3: a non-critical service that cannot be linked must WARN and let the
# install continue — an abort here would be the regression, not the fix.
root3="${TMP_ROOT}/readonly"
mkdir -p "${root3}/etc/sv/cupsd" "${root3}/var/service"
chmod 500 "${root3}/var/service"
assert_true "unlinkable NON-critical service does not abort" \
    _reaches_next_statement "${root3}" "cupsd"
assert_true "...and is recorded in SKIPPED_LOG so it is not silent" \
    grep -q 'cupsd' "${TMP_ROOT}/skipped.log"
chmod 700 "${root3}/var/service"

# Case 4: a missing /etc/sv entry — same contract. `try` offers "skip this step",
# and a skipped xbps-install leaves exactly this state a few lines later.
root4="${TMP_ROOT}/missing"
mkdir -p "${root4}/var/service"
assert_true "missing service definition does not abort either" \
    _reaches_next_statement "${root4}" "nosuchservice"

# Case 5: the critical list MUST abort. This is the assertion that survived a
# mutation before — now it distinguishes die from return by testing whether the
# next statement runs at all.
root5="${TMP_ROOT}/critical"
mkdir -p "${root5}/etc/sv/udevd" "${root5}/var/service"
chmod 500 "${root5}/var/service"
assert_false "unlinkable CRITICAL service aborts the install" \
    _reaches_next_statement "${root5}" "udevd"
chmod 700 "${root5}/var/service"

# Case 6: re-enabling an already-enabled service must REFRESH the link, not
# create one inside the service directory. runit-void enables agetty-tty1..6 and
# udevd itself, so system_finalize always hits this path; plain `ln -sf` would
# dereference the existing symlink and produce /etc/sv/<svc>/<svc>.
root6="${TMP_ROOT}/already"
mkdir -p "${root6}/etc/sv/agetty-tty1" "${root6}/var/service"
# Point INSIDE the fake root, like case 2 — an absolute /etc/sv/... would resolve
# against the host, where it does not exist, so the link would dangle and plain
# `ln -sf` would have nothing to dereference. That made this assertion pass
# against the very regression it guards (verified by mutation).
ln -s "${root6}/etc/sv/agetty-tty1" "${root6}/var/service/agetty-tty1"
# Subshell + `|| true`: agetty-tty1 is on the critical list, so a regression here
# ends in die() — which would kill the whole suite instead of failing this case.
# Contain it and let the assertions below report what actually happened on disk.
( SERVICE_ROOT="${root6}" _enable_service "agetty-tty1" ) >/dev/null 2>&1 || true
assert_false "no self-referential link inside the service dir" \
    test -e "${root6}/etc/sv/agetty-tty1/agetty-tty1"
# `|| echo` matters: under `set -e` a failing readlink would abort the whole
# suite instead of reporting a FAIL, which is what happened when this was
# mutation-tested — a broken link killed the run rather than failing the case.
assert_eq "existing link still points at the service" "/etc/sv/agetty-tty1" \
    "$(readlink "${root6}/var/service/agetty-tty1" 2>/dev/null || echo '<brak dowiązania>')"

# The list itself is part of the contract: these are the services whose absence
# leaves a machine with no console, no seat and no login.
for svc in udevd dbus elogind agetty-tty1 sddm; do
    assert_true "${svc} is on the critical list" \
        grep -q " ${svc} " <<< " ${_CRITICAL_SERVICES} "
done

echo ""
echo "=== _configure_sudo_wheel: drop-in, verified, not a blind sed ==="

# Case 1: normal Void layout — /etc/sudoers pulls in the directory.
sroot1="${TMP_ROOT}/sudo-ok"
mkdir -p "${sroot1}/etc"
printf 'Defaults env_reset\n#includedir /etc/sudoers.d\n' > "${sroot1}/etc/sudoers"
rc=0
SUDO_ROOT="${sroot1}" _configure_sudo_wheel >/dev/null 2>&1 || rc=$?
assert_eq "drop-in path succeeds" "0" "${rc}"
assert_true "drop-in file created" test -f "${sroot1}/etc/sudoers.d/10-wheel"
assert_eq "drop-in grants wheel" "%wheel ALL=(ALL:ALL) ALL" \
    "$(cat "${sroot1}/etc/sudoers.d/10-wheel" 2>/dev/null)"
assert_eq "drop-in mode is 0440" "440" \
    "$(stat -c '%a' "${sroot1}/etc/sudoers.d/10-wheel" 2>/dev/null)"

# Case 2: modern sudo writes @includedir, not #includedir — both are directives.
sroot2="${TMP_ROOT}/sudo-at"
mkdir -p "${sroot2}/etc"
printf 'Defaults env_reset\n@includedir /etc/sudoers.d\n' > "${sroot2}/etc/sudoers"
SUDO_ROOT="${sroot2}" _configure_sudo_wheel >/dev/null 2>&1
assert_true "@includedir is recognised as an include, not a comment" \
    test -f "${sroot2}/etc/sudoers.d/10-wheel"

# Case 3: no includedir at all — fall back to editing /etc/sudoers, and only
# report success if the %wheel line is actually active afterwards.
sroot3="${TMP_ROOT}/sudo-noinc"
mkdir -p "${sroot3}/etc"
printf 'Defaults env_reset\n# %%wheel ALL=(ALL:ALL) ALL\n' > "${sroot3}/etc/sudoers"
rc=0
SUDO_ROOT="${sroot3}" _configure_sudo_wheel >/dev/null 2>&1 || rc=$?
assert_eq "fallback path succeeds when the sed matches" "0" "${rc}"
assert_true "%wheel line un-commented by the fallback" \
    grep -Eq '^%wheel ALL=' "${sroot3}/etc/sudoers"

# Case 4: the case the old code got wrong — no includedir AND a comment the sed
# does not match. It used to swallow this and leave the user without sudo.
sroot4="${TMP_ROOT}/sudo-nomatch"
mkdir -p "${sroot4}/etc"
printf 'Defaults env_reset\n#\t%%wheel ALL=(ALL:ALL) ALL\n' > "${sroot4}/etc/sudoers"
rc=0
SUDO_ROOT="${sroot4}" _configure_sudo_wheel >/dev/null 2>&1 || rc=$?
assert_eq "unmatched sed pattern reports failure instead of silence" "1" "${rc}"

echo ""
echo "=== drop_dns_info: the live medium's resolv.conf does not survive ==="

# This used to live in system_finalize() and be asserted with a grep over
# `declare -f`. Two problems, both found in review: the grep passed even after
# `rm -f` was moved OUT of the DRY_RUN guard (verified by mutation — a dry run
# would then delete the resolv.conf of the machine running the installer), and
# system_finalize is gated by the `finalize` checkpoint while copy_dns_info runs
# on every entry into the chroot phase, so a resumed install put the file back
# and nothing removed it again. Now it is a function of its own, operating on
# MOUNTPOINT, called from the caller — which makes it testable for real.

_mk_target() {
    local t="$1"
    mkdir -p "${t}/etc/sv/NetworkManager"
    echo "nameserver 10.0.0.1" > "${t}/etc/resolv.conf"
}

# Real run: the file goes.
tgt1="${TMP_ROOT}/target-live"
_mk_target "${tgt1}"
MOUNTPOINT="${tgt1}" DRY_RUN=0 drop_dns_info >/dev/null 2>&1
assert_false "resolv.conf removed on a real run" test -f "${tgt1}/etc/resolv.conf"

# Dry run: it must NOT. This is the destructive one — the installer often runs
# from a live medium whose own resolver is the only network it has.
tgt2="${TMP_ROOT}/target-dry"
_mk_target "${tgt2}"
MOUNTPOINT="${tgt2}" DRY_RUN=1 drop_dns_info >/dev/null 2>&1
assert_true "dry run leaves resolv.conf alone" test -f "${tgt2}/etc/resolv.conf"

# No NetworkManager in the target (the networking phase can be skipped via try):
# nothing would regenerate the file, so a frozen resolver beats no resolver.
tgt3="${TMP_ROOT}/target-nonm"
mkdir -p "${tgt3}/etc"
echo "nameserver 10.0.0.1" > "${tgt3}/etc/resolv.conf"
MOUNTPOINT="${tgt3}" DRY_RUN=0 drop_dns_info >/dev/null 2>&1
assert_true "kept when nothing in the target would regenerate it" \
    test -f "${tgt3}/etc/resolv.conf"

# Wiring: the removal must sit OUTSIDE the checkpointed phase, paired with
# copy_dns_info, and after run_chroot_phase (so the after_finalize hook still
# has name resolution).
prog=$(cat "${SCRIPT_DIR}/tui/progress.sh")
assert_false "system_finalize no longer touches resolv.conf" \
    grep -q 'resolv.conf' <<< "$(declare -f system_finalize)"
assert_true "drop_dns_info called from the chroot-phase caller" \
    grep -q 'drop_dns_info' <<< "${prog}"
drop_line=$(grep -n 'drop_dns_info' <<< "${prog}" | head -1 | cut -d: -f1)
run_line=$(grep -n 'run_chroot_phase$' <<< "${prog}" | head -1 | cut -d: -f1)
tear_line=$(grep -n 'chroot_teardown$' <<< "${prog}" | head -1 | cut -d: -f1)
assert_true "runs after run_chroot_phase (hook keeps DNS)" test "${drop_line}" -gt "${run_line}"
assert_true "runs before chroot_teardown (target still mounted)" test "${drop_line}" -lt "${tear_line}"

echo ""
echo "=== setup_periodic_trim: runit has no fstrim.timer (Forgejo #23) ==="

# Stub the two things that would touch the real system. _ensure_cronie is
# exercised separately below; here we only care about the cron job itself.
_ensure_cronie() { CRONIE_CALLED=1; }

# SSD: the job is written, executable, and runs fstrim across all filesystems.
troot1="${TMP_ROOT}/trim-ssd"
mkdir -p "${troot1}/sys/block/nvme0n1/queue"
echo 0 > "${troot1}/sys/block/nvme0n1/queue/rotational"
CRONIE_CALLED=0
TRIM_ROOT="${troot1}" TARGET_DISK=/dev/nvme0n1 setup_periodic_trim >/dev/null 2>&1
assert_true "cron job created for an SSD" test -f "${troot1}/etc/cron.weekly/fstrim"
assert_true "cron job is executable (run-parts skips it otherwise)" \
    test -x "${troot1}/etc/cron.weekly/fstrim"
assert_eq "job mode is 0755" "755" \
    "$(stat -c '%a' "${troot1}/etc/cron.weekly/fstrim" 2>/dev/null)"
assert_true "trims every mounted filesystem, not just root" \
    grep -q 'fstrim -av' "${troot1}/etc/cron.weekly/fstrim"
assert_eq "cronie ensured — nothing would run the job otherwise" "1" "${CRONIE_CALLED}"

# Spinning disk: nothing scheduled. fstrim on an HDD is pointless work.
troot2="${TMP_ROOT}/trim-hdd"
mkdir -p "${troot2}/sys/block/sda/queue"
echo 1 > "${troot2}/sys/block/sda/queue/rotational"
CRONIE_CALLED=0
TRIM_ROOT="${troot2}" TARGET_DISK=/dev/sda setup_periodic_trim >/dev/null 2>&1
assert_false "no cron job for a rotational disk" test -e "${troot2}/etc/cron.weekly/fstrim"
assert_eq "and cronie is not pulled in for nothing" "0" "${CRONIE_CALLED}"

# Unknown device: schedule anyway. `fstrim -av` skips filesystems that cannot
# discard, so this costs nothing — while skipping would silently drop TRIM on
# dm/md/virtio stacks, i.e. the machines most likely to need it.
troot3="${TMP_ROOT}/trim-unknown"
mkdir -p "${troot3}/sys/block"
CRONIE_CALLED=0
TRIM_ROOT="${troot3}" TARGET_DISK=/dev/mapper/vg-root setup_periodic_trim >/dev/null 2>&1
assert_true "unclassifiable device still gets TRIM" \
    test -f "${troot3}/etc/cron.weekly/fstrim"

# No target disk at all (a resume that lost its config): warn, do not crash.
troot4="${TMP_ROOT}/trim-nodisk"
mkdir -p "${troot4}"
rc=0
TRIM_ROOT="${troot4}" TARGET_DISK="" setup_periodic_trim >/dev/null 2>&1 || rc=$?
assert_eq "missing TARGET_DISK is survivable" "0" "${rc}"
assert_false "...and schedules nothing" test -e "${troot4}/etc/cron.weekly/fstrim"

unset -f _ensure_cronie

# TRIM must not depend on snapshots being enabled — that was the whole point of
# splitting cronie out of snapper_setup.
assert_false "snapper no longer owns the cronie install" \
    grep -q 'xbps-install -y snapper grub-btrfs cronie' <<< "$(declare -f snapper_setup)"
assert_true "snapper goes through the shared helper" \
    grep -q '_ensure_cronie' <<< "$(declare -f snapper_setup)"
assert_true "and the TRIM path does too" \
    grep -q '_ensure_cronie' <<< "$(declare -f setup_periodic_trim)"

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
