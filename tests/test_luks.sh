#!/usr/bin/env bash
# tests/test_luks.sh — LUKS planning, secret handling and system wiring.
# The passphrase must never reach the log or a command line; the container
# must never be re-formatted on a resume. Both are asserted here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-luks.log"
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
source "${LIB_DIR}/disk.sh"
source "${LIB_DIR}/luks.sh"

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
        echo "  FAIL: ${desc} — '${needle}' not in output"; (( FAIL++ )) || true
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' WAS found (must not be)"; (( FAIL++ )) || true
    fi
}

# _save_fn / _restore_fn — stub a library function and put the original back.
#
# Neither `unset -f` nor re-sourcing works here: the first DROPS the real
# definition (bash keeps no stack of them), and lib/constants.sh marks values
# like DIALOG_HEIGHT readonly, so a second `source lib/dialog.sh` aborts the
# test file. Copying the body under another name is the only safe route.
_save_fn() {
    eval "_orig_$1() $(declare -f "$1" | tail -n +2)"
}
_restore_fn() {
    eval "$1() $(declare -f "_orig_$1" | tail -n +2)"
}

# Common config for a plain auto-partition run
_setup_config() {
    TARGET_DISK="/dev/sda"
    FILESYSTEM="ext4"
    SWAP_TYPE="zram"
    PARTITION_SCHEME="auto"
    LUKS_ENABLED="yes"
    LUKS_NAME="cryptroot"
    _LUKS_PASSPHRASE="correct horse battery staple"
    ESP_PARTITION=""; ROOT_PARTITION=""; SWAP_PARTITION=""; LUKS_PARTITION=""
}

echo "=== Plan: LUKS sits between partitioning and mkfs ==="

# blkid stub: a fresh disk, no LUKS header yet
blkid() { return 1; }

DRY_RUN=0
_setup_config
disk_plan_auto

assert_eq "raw partition recorded as the container" "/dev/sda2" "${LUKS_PARTITION}"
assert_eq "root points at the mapper device" "/dev/mapper/cryptroot" "${ROOT_PARTITION}"

plan_text=$(printf '%s\n' "${DISK_ACTIONS[@]}")
assert_contains "plan formats the container"   "luksFormat" "${plan_text}"
assert_contains "plan opens the container"     "luksOpen"   "${plan_text}"
assert_contains "plan adds the initramfs keyfile" "luksAddKey" "${plan_text}"
assert_contains "mkfs targets the mapper"      "mkfs.ext4" "${plan_text}"

# Ordering matters: formatting the filesystem before opening the container
# would write ext4 over the LUKS header.
fmt_idx=-1; open_idx=-1; mkfs_idx=-1
for i in "${!DISK_ACTIONS[@]}"; do
    [[ "${DISK_ACTIONS[$i]}" == *luksFormat* && ${fmt_idx} -lt 0 ]] && fmt_idx=${i}
    [[ "${DISK_ACTIONS[$i]}" == *luksOpen* && ${open_idx} -lt 0 ]] && open_idx=${i}
    [[ "${DISK_ACTIONS[$i]}" == *mkfs.ext4* && ${mkfs_idx} -lt 0 ]] && mkfs_idx=${i}
done
assert_eq "luksFormat precedes luksOpen" "yes" "$( [[ ${fmt_idx} -lt ${open_idx} ]] && echo yes || echo no )"
assert_eq "luksOpen precedes mkfs"       "yes" "$( [[ ${open_idx} -lt ${mkfs_idx} ]] && echo yes || echo no )"

echo ""
echo "=== The passphrase never leaks ==="

# Every LUKS action must be flagged secret...
secret_count=0
for i in "${!DISK_STDIN[@]}"; do
    if [[ -n "${DISK_STDIN[$i]}" && "${DISK_SECRET[$i]:-0}" == "1" ]]; then
        (( secret_count++ )) || true
        assert_eq "secret payload $i is the passphrase" "correct horse battery staple" "${DISK_STDIN[$i]}"
    fi
done
assert_eq "three secret actions (format, open, addkey)" "3" "${secret_count}"

# ...and the sfdisk script must NOT be, or it would be masked pointlessly
assert_eq "sfdisk stdin is not marked secret" "0" "${DISK_SECRET[0]}"

# disk_plan_show writes to the log — the passphrase must not appear there
: > "${LOG_FILE}"
disk_plan_show >/dev/null 2>&1
log_text=$(cat "${LOG_FILE}")
assert_not_contains "passphrase absent from the log" "correct horse battery staple" "${log_text}"
assert_contains "log says the payload was withheld" "secret withheld" "${log_text}"

echo ""
echo "=== TRIM on the encrypted root (Forgejo #25) ==="

# The mapping the installer itself works through: with discard off, mkfs must
# not be handed an allow-discards mapping, and with it on it must be.
blkid() { return 1; }
DRY_RUN=0

_setup_config
LUKS_ALLOW_DISCARDS="no"
disk_plan_auto
plan_text=$(printf '%s\n' "${DISK_ACTIONS[@]}")
assert_not_contains "luksOpen has no --allow-discards by default" \
    "--allow-discards" "${plan_text}"

_setup_config
LUKS_ALLOW_DISCARDS="yes"
disk_plan_auto
plan_text=$(printf '%s\n' "${DISK_ACTIONS[@]}")
assert_contains "luksOpen gets --allow-discards when asked for" \
    "--allow-discards" "${plan_text}"

# It has to be the OPEN action carrying it — the format step neither needs nor
# accepts the flag, and a mapping opened without it ignores discard for the
# whole install. Actions are "desc|||cmd" with the command %q-quoted, so match
# per action rather than on the flattened plan text.
open_action=""; format_action=""
for a in "${DISK_ACTIONS[@]}"; do
    [[ "${a}" == *"Open LUKS container"* ]] && open_action="${a}"
    [[ "${a}" == *"Set up LUKS encryption"* ]] && format_action="${a}"
done
assert_contains "the open action is the one carrying it" \
    "--allow-discards" "${open_action}"
assert_not_contains "the luksFormat action does not" \
    "--allow-discards" "${format_action}"

unset -f blkid

# crypttab options field — what dm-crypt reads at every boot
_crypttab_for() {
    local want="$1"
    local tmp; tmp=$(mktemp -d)
    (
        get_uuid() { echo "1234abcd-5678-90ef-1234-567890abcdef"; }
        LUKS_CRYPTTAB="${tmp}/crypttab"
        LUKS_PARTITION="/dev/sda2"
        LUKS_NAME="cryptroot"
        LUKS_ALLOW_DISCARDS="${want}"
        LUKS_KEYFILE_STAGE="/nonexistent-stage"
        _luks_write_crypttab
    ) >/dev/null 2>&1
    cat "${tmp}/crypttab" 2>/dev/null
    rm -rf "${tmp}"
}

ct_off=$(_crypttab_for "no")
ct_on=$(_crypttab_for "yes")

assert_contains "crypttab carries the plain luks options field by default" \
    "none luks" "${ct_off}"
assert_not_contains "…and no discard" "discard" "${ct_off}"
# dracut's option loop matches `allow-discards`; systemd's `discard` spelling
# falls through its case with no branch and is silently ignored, so the wrong
# token would leave TRIM off with no error anywhere.
assert_contains "crypttab carries allow-discards when allowed" "luks,allow-discards" "${ct_on}"
assert_not_contains "…and not systemd's 'discard' spelling, which dracut ignores" \
    "luks,discard" "${ct_on}"

# Kernel cmdline — dracut reads this even when crypttab is not in the image
get_uuid() { echo "1234abcd-5678-90ef-1234-567890abcdef"; }
LUKS_ENABLED="yes"
LUKS_PARTITION="/dev/sda2"
LUKS_KEYFILE_TARGET="/nonexistent-keyfile"

LUKS_ALLOW_DISCARDS="no"
assert_not_contains "cmdline has no allow-discards by default" \
    "allow-discards" "$(luks_grub_cmdline)"

LUKS_ALLOW_DISCARDS="yes"
cmdline=$(luks_grub_cmdline)
# The valueless form on purpose: dracut compares the requested UUIDs against a
# variable cryptroot-ask.sh never assigns, so the =<uuid> form can never match
# and skips the valueless branch too — a silent no-op. Scope still comes from
# rd.luks.uuid, which the same cmdline always carries.
assert_contains "cmdline carries rd.luks.allow-discards when allowed" \
    "rd.luks.allow-discards" "${cmdline}"
assert_not_contains "…not the per-UUID form, which dracut cannot match" \
    "rd.luks.allow-discards=" "${cmdline}"
assert_contains "…alongside rd.luks.uuid, which limits it to this container" \
    "rd.luks.uuid=1234abcd" "${cmdline}"
unset -f get_uuid
LUKS_ALLOW_DISCARDS="no"

# --- The TUI screen, tested by RESULT, not by grepping its source ---
#
# A grep for "defaultno" in the file passes even when the prompt is never
# called and when the yes-branch is inverted — both of which silently restore
# the pre-#25 behaviour. So drive the real screen function with a stubbed
# dialog and assert on the variable it is supposed to produce.
# TUI_NEXT/BACK/ABORT are readonly in lib/constants.sh — already sourced.
#
# DRY_RUN back to 1 first: the disk-planning section above left it at 0, and
# _screen_luks_prompt then guards on `command -v cryptsetup`. On a machine
# without cryptsetup the screen bails out before the TRIM question is ever
# asked, and every assertion below silently tests the wrong branch — the
# documented "test depends on the HOST's environment" trap.
DRY_RUN=1
TUI_DIR="${SCRIPT_DIR}/tui"
source "${TUI_DIR}/filesystem_select.sh"

_save_fn dialog_yesno
_save_fn luks_prompt_passphrase
luks_prompt_passphrase() { _LUKS_PASSPHRASE="pw"; return 0; }

# Stub routes by title: the first question is encryption, the second is TRIM.
_TRIM_ASKED=0
_TRIM_DEFAULT_ARG=""
dialog_yesno() {
    local title="$1" default="${3:-}"
    case "${title}" in
        *"Encryption"*) return "${_ANS_LUKS:-0}" ;;
        *"TRIM"*)
            _TRIM_ASKED=1
            _TRIM_DEFAULT_ARG="${default}"
            return "${_ANS_TRIM:-1}"
            ;;
    esac
    return 1
}

_run_luks_screen() {
    PARTITION_SCHEME="${1:-auto}"
    _TRIM_ASKED=0
    _TRIM_DEFAULT_ARG=""
    _screen_luks_prompt >/dev/null 2>&1
}

# user says yes to encryption, yes to TRIM
LUKS_ALLOW_DISCARDS="no"; _ANS_LUKS=0; _ANS_TRIM=0
_run_luks_screen auto
assert_eq "screen asks about TRIM when encryption is on" "1" "${_TRIM_ASKED}"
assert_eq "…and a yes answer reaches LUKS_ALLOW_DISCARDS" "yes" "${LUKS_ALLOW_DISCARDS}"
assert_eq "…asked with the selection parked on No" "defaultno" "${_TRIM_DEFAULT_ARG}"

# user says yes to encryption, no to TRIM
LUKS_ALLOW_DISCARDS="yes"; _ANS_LUKS=0; _ANS_TRIM=1
_run_luks_screen auto
assert_eq "a no answer reaches LUKS_ALLOW_DISCARDS" "no" "${LUKS_ALLOW_DISCARDS}"

# encryption declined — a stale yes from a preset must not survive, or
# validate_config rejects the config on a screen the user cannot get back to
LUKS_ALLOW_DISCARDS="yes"; _ANS_LUKS=1; _ANS_TRIM=0
_run_luks_screen auto
assert_eq "no TRIM question when encryption is declined" "0" "${_TRIM_ASKED}"
assert_eq "…and a stale preset yes is cleared" "no" "${LUKS_ALLOW_DISCARDS}"
assert_eq "…encryption itself stays off" "no" "${LUKS_ENABLED}"

# a spinning disk: no cron job is ever written for it, so a "yes" would buy
# nothing and the question must not be asked at all
# `unset -f` is safe HERE and only here: this file never sources lib/system.sh,
# so the stub has no library original to destroy (the screen guards the call
# with `declare -F`, which is why every assertion above ran without it).
_disk_is_rotational() { return 0; }
LUKS_ALLOW_DISCARDS="yes"; _ANS_LUKS=0; _ANS_TRIM=0
TARGET_DISK="/dev/sda"
_run_luks_screen auto
assert_eq "no TRIM question on a rotational disk" "0" "${_TRIM_ASKED}"
assert_eq "…and the answer is forced to no" "no" "${LUKS_ALLOW_DISCARDS}"
unset -f _disk_is_rotational
assert_eq "the stub is gone again" "" "$(declare -F _disk_is_rotational || true)"

# manual partitioning — the installer never creates this container
LUKS_ALLOW_DISCARDS="yes"; _ANS_LUKS=0; _ANS_TRIM=0
_run_luks_screen manual
assert_eq "manual scheme asks nothing about TRIM" "0" "${_TRIM_ASKED}"
assert_eq "…and clears a stale preset yes" "no" "${LUKS_ALLOW_DISCARDS}"

_restore_fn dialog_yesno
_restore_fn luks_prompt_passphrase
PARTITION_SCHEME="auto"
LUKS_ALLOW_DISCARDS="no"

# dialog_yesno must pass the flag through to the dialog/whiptail backend…
captured=""
_save_fn dialog_yesno
dialog() { captured="$*"; return 1; }
DIALOG_CMD="dialog" dialog_yesno "T" "text" "defaultno" || true
assert_contains "dialog_yesno forwards --defaultno" "--defaultno" "${captured}"
captured=""
DIALOG_CMD="dialog" dialog_yesno "T" "text" || true
assert_not_contains "…and omits it otherwise" "--defaultno" "${captured}"
unset -f dialog   # a stub with no library original — safe to drop

# …and to gum, which is the DEFAULT backend on the live medium (bundled in
# data/gum.tar.gz, first in the detection order) — there the default answer is
# expressed as the order of the choices, so it needs its own assertion.
if [[ -c /dev/tty ]]; then
    # The stub runs inside $( … ), so it captures to a FILE — a variable
    # assigned in that subshell never reaches this one (which is exactly how
    # the first version of this assertion managed to compare empty to empty).
    gum_capture="$(mktemp)"
    _save_fn _gum_backtitle
    _save_fn _gum_style_box
    _save_fn _gum_drain_tty
    gum() { cat > "${gum_capture}"; echo "No"; }
    _gum_backtitle() { :; }
    _gum_style_box() { :; }
    _gum_drain_tty() { :; }

    : > "${gum_capture}"
    DIALOG_CMD="gum" dialog_yesno "T" "text" "defaultno" >/dev/null 2>&1 || true
    assert_eq "gum puts No first when the default is No" "No" "$(head -1 "${gum_capture}")"

    : > "${gum_capture}"
    DIALOG_CMD="gum" dialog_yesno "T" "text" >/dev/null 2>&1 || true
    assert_eq "gum puts Yes first otherwise" "Yes" "$(head -1 "${gum_capture}")"
    rm -f "${gum_capture}"

    _restore_fn _gum_backtitle
    _restore_fn _gum_style_box
    _restore_fn _gum_drain_tty
    unset -f gum
else
    echo "  SKIP: no /dev/tty — gum backend assertions not run"
fi
DIALOG_CMD="dialog"

# --- luks_open_for_resume: the OTHER path that opens the mapping ---
#
# The plan path (_plan_luks_setup) is covered above; this one was rewritten by
# the same change to pass cryptsetup's arguments positionally ("${@:3}"), which
# is exactly the shape where an off-by-one produces a command that runs, fails,
# and leaves a resumed install with no root mounted.
resume_dev=$(lsblk -dnpo NAME 2>/dev/null | head -1) || true
if [[ -b "${resume_dev:-}" ]]; then
    cs_dir=$(mktemp -d)
    cs_log="${cs_dir}/argv"
    cat > "${cs_dir}/cryptsetup" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${_CS_ARGV_LOG}"
cat > "${_CS_STDIN_LOG}"
exit 0
STUB
    chmod 0755 "${cs_dir}/cryptsetup"
    export _CS_ARGV_LOG="${cs_log}" _CS_STDIN_LOG="${cs_dir}/stdin"
    _old_path="${PATH}"
    export PATH="${cs_dir}:${PATH}"

    LUKS_ENABLED="yes"
    LUKS_PARTITION="${resume_dev}"
    LUKS_NAME="void-test-mapper-absent"
    _LUKS_PASSPHRASE="correct horse battery staple"

    LUKS_ALLOW_DISCARDS="no"
    luks_open_for_resume >/dev/null 2>&1 || true
    argv=$(cat "${cs_log}" 2>/dev/null)
    assert_eq "resume opens with luksOpen as the action" "luksOpen" "$(head -1 <<< "${argv}")"
    assert_contains "…on the right partition" "${resume_dev}" "${argv}"
    assert_not_contains "…without --allow-discards by default" "--allow-discards" "${argv}"
    assert_not_contains "…and never the passphrase in argv" "correct horse battery staple" "${argv}"
    assert_eq "…passphrase goes through stdin" "correct horse battery staple" \
        "$(cat "${cs_dir}/stdin" 2>/dev/null)"

    : > "${cs_log}"
    LUKS_ALLOW_DISCARDS="yes"
    luks_open_for_resume >/dev/null 2>&1 || true
    argv=$(cat "${cs_log}" 2>/dev/null)
    assert_eq "resume still opens with luksOpen first" "luksOpen" "$(head -1 <<< "${argv}")"
    assert_contains "…and carries --allow-discards when allowed" "--allow-discards" "${argv}"

    export PATH="${_old_path}"
    unset _CS_ARGV_LOG _CS_STDIN_LOG
    rm -rf "${cs_dir}"
    LUKS_ALLOW_DISCARDS="no"
    LUKS_NAME="cryptroot"
else
    echo "  SKIP: no block device available — luks_open_for_resume argv not exercised"
fi

# --- dracut configuration ---
#
# Void builds a GENERIC initramfs, and dracut's crypt module only copies
# /etc/crypttab into the image when hostonly is on — so without an explicit
# install_items the options written above never reach early boot at all.
dr_root=$(mktemp -d)
_save_fn try
try() { :; }   # the writer ends with a dracut run we must not perform here
(
    LUKS_DRACUT_CONF="${dr_root}/10-luks.conf"
    LUKS_KEYFILE_TARGET="/nonexistent-keyfile"
    _luks_write_dracut_conf
) >/dev/null 2>&1
_restore_fn try
dracut_conf=$(cat "${dr_root}/10-luks.conf" 2>/dev/null)
assert_contains "dracut config pulls /etc/crypttab into the image" \
    'install_items+=" /etc/crypttab "' "${dracut_conf}"
assert_contains "…and still adds the crypt module" \
    'add_dracutmodules+=" crypt "' "${dracut_conf}"
rm -rf "${dr_root}"

# --- the default really is "no" ---
#
# Every consumer reads ${LUKS_ALLOW_DISCARDS:-no}; with the variable unset (a
# config from before this option existed, or a partial resume) nothing may turn
# discard on by itself.
(
    unset LUKS_ALLOW_DISCARDS
    get_uuid() { echo "1234abcd-5678-90ef-1234-567890abcdef"; }
    LUKS_ENABLED="yes"; LUKS_PARTITION="/dev/sda2"
    LUKS_KEYFILE_TARGET="/nonexistent-keyfile"
    tmp=$(mktemp -d); LUKS_CRYPTTAB="${tmp}/crypttab"
    LUKS_KEYFILE_STAGE="/nonexistent-stage"
    _luks_write_crypttab >/dev/null 2>&1
    printf '%s|%s' "$(cat "${tmp}/crypttab")" "$(luks_grub_cmdline)"
    rm -rf "${tmp}"
) > /tmp/void-test-luks-default.$$ 2>/dev/null
unset_out=$(cat "/tmp/void-test-luks-default.$$"); rm -f "/tmp/void-test-luks-default.$$"
assert_not_contains "an unset LUKS_ALLOW_DISCARDS never enables discard" \
    "discard" "${unset_out}"
assert_contains "…but the rest of the wiring is still written" "luks" "${unset_out}"

# --- verify_luks_discards: the post-phase check the repo's doctrine asks for ---
vd_out=$(LUKS_ALLOW_DISCARDS="no" verify_luks_discards 2>&1)
assert_eq "verification is silent when TRIM was not requested" "" "${vd_out}"

vd_tmp=$(mktemp -d)
printf 'cryptroot UUID=x none luks\n' > "${vd_tmp}/crypttab"
vd_out=$(LUKS_ALLOW_DISCARDS="yes" LUKS_CRYPTTAB="${vd_tmp}/crypttab" \
    LUKS_NAME="void-test-mapper-absent" verify_luks_discards 2>&1)
assert_contains "a crypttab without the option is reported" "allow-discards" "${vd_out}"

printf 'cryptroot UUID=x none luks,allow-discards\n' > "${vd_tmp}/crypttab"
vd_out=$(LUKS_ALLOW_DISCARDS="yes" LUKS_CRYPTTAB="${vd_tmp}/crypttab" \
    LUKS_NAME="void-test-mapper-absent" verify_luks_discards 2>&1)
assert_not_contains "a correct crypttab raises no complaint about itself" \
    "has no allow-discards" "${vd_out}"
rm -rf "${vd_tmp}"

# A resumed run rewrites crypttab, so the discard decision has to be read back
# from the installed system — otherwise resume silently revokes it.
infer_root=$(mktemp -d)
mkdir -p "${infer_root}/etc"

printf 'cryptroot /dev/sda2 /boot/luks-keyfile luks,allow-discards\n' \
    > "${infer_root}/etc/crypttab"
LUKS_ALLOW_DISCARDS=""
_infer_luks_from_installed "${infer_root}" >/dev/null 2>&1
assert_eq "resume reads allow-discards back from crypttab" "yes" "${LUKS_ALLOW_DISCARDS}"

# systemd's spelling too — the file may have been written by hand or by
# another distribution, and reading someone's existing decision is where
# being liberal is right
printf 'cryptroot /dev/sda2 /boot/luks-keyfile luks,discard\n' \
    > "${infer_root}/etc/crypttab"
LUKS_ALLOW_DISCARDS=""
_infer_luks_from_installed "${infer_root}" >/dev/null 2>&1
assert_eq "resume also understands systemd's 'discard' spelling" "yes" "${LUKS_ALLOW_DISCARDS}"

# tabs and padding must not hide the options field
printf 'cryptroot\t/dev/sda2\tnone\tluks,allow-discards\n' \
    > "${infer_root}/etc/crypttab"
LUKS_ALLOW_DISCARDS=""
_infer_luks_from_installed "${infer_root}" >/dev/null 2>&1
assert_eq "tab-separated crypttab is parsed too" "yes" "${LUKS_ALLOW_DISCARDS}"
assert_eq "…along with the container partition" "/dev/sda2" "${LUKS_PARTITION}"

printf 'cryptroot /dev/sda2 /boot/luks-keyfile luks\n' \
    > "${infer_root}/etc/crypttab"
LUKS_ALLOW_DISCARDS="yes"
_infer_luks_from_installed "${infer_root}" >/dev/null 2>&1
assert_eq "a crypttab without discard resumes as no" "no" "${LUKS_ALLOW_DISCARDS}"

# "nodiscard" and "discard-me" must not read as discard
printf 'cryptroot /dev/sda2 none luks,nodiscard\n' \
    > "${infer_root}/etc/crypttab"
LUKS_ALLOW_DISCARDS="yes"
_infer_luks_from_installed "${infer_root}" >/dev/null 2>&1
assert_eq "a substring match does not count as discard" "no" "${LUKS_ALLOW_DISCARDS}"

rm -rf "${infer_root}"
LUKS_ALLOW_DISCARDS="no"

# Back to the disk-planning mode the sections below expect: _plan_luks_setup
# skips the real cryptsetup steps under DRY_RUN=1, so leaving it on here would
# make "the container is opened" assert against a plan that never opens it.
DRY_RUN=0

echo ""
echo "=== Resume: an existing container is opened, never re-formatted ==="

# blkid stub: partition already carries a LUKS header
blkid() { echo "crypto_LUKS"; return 0; }

_setup_config
disk_plan_auto
plan_text=$(printf '%s\n' "${DISK_ACTIONS[@]}")

assert_not_contains "no luksFormat on an existing container" "luksFormat" "${plan_text}"
assert_contains     "still opens the container"              "luksOpen"   "${plan_text}"
assert_not_contains "no extra key slot burned on resume"     "luksAddKey" "${plan_text}"

unset -f blkid
DRY_RUN=1

echo ""
echo "=== Dual-boot uses the same path ==="

blkid() { return 1; }
DRY_RUN=0
_setup_config
PARTITION_SCHEME="dual-boot"
ESP_PARTITION="/dev/sda1"
ROOT_PARTITION="/dev/sda3"
disk_plan_dualboot

assert_eq "dual-boot records the container partition" "/dev/sda3" "${LUKS_PARTITION}"
assert_eq "dual-boot root is the mapper" "/dev/mapper/cryptroot" "${ROOT_PARTITION}"
unset -f blkid
DRY_RUN=1

echo ""
echo "=== GRUB cmdline ==="

get_uuid() { echo "1234abcd-5678-90ef-1234-567890abcdef"; }
LUKS_ENABLED="yes"
LUKS_PARTITION="/dev/sda2"
LUKS_KEYFILE_TARGET="/nonexistent-keyfile"
cmdline=$(luks_grub_cmdline)
assert_contains "cmdline carries rd.luks.uuid" "rd.luks.uuid=1234abcd" "${cmdline}"
assert_not_contains "no rd.luks.key when the keyfile is absent" "rd.luks.key" "${cmdline}"

LUKS_ENABLED="no"
assert_eq "no cmdline when LUKS is off" "" "$(luks_grub_cmdline)"
unset -f get_uuid

echo ""
echo "=== Validation gates ==="

_valid_base() {
    TARGET_DISK="/dev/sda"; PARTITION_SCHEME="auto"; FILESYSTEM="ext4"
    SWAP_TYPE="zram"; HOSTNAME="void"; TIMEZONE="Europe/Warsaw"
    LOCALE="en_US.UTF-8"; KEYMAP="us"; KERNEL_TYPE="mainline"
    GPU_VENDOR="intel"; DESKTOP_TYPE="kde"; USERNAME="user"
    ROOT_PASSWORD_HASH='$6$x$y'; USER_PASSWORD_HASH='$6$x$y'
    ESP_PARTITION="/dev/sda1"; ROOT_PARTITION="/dev/sda2"
    LUKS_ENABLED="no"; LUKS_PARTITION=""; LUKS_ALLOW_DISCARDS="no"
}

_valid_base
LUKS_ENABLED="maybe"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "bad LUKS_ENABLED rejected" "1" "${rc}"
assert_contains "message names LUKS_ENABLED" "LUKS_ENABLED" "${out}"

# LUKS_PARTITION is assigned by disk_plan_auto/disk_plan_dualboot, which run
# AFTER every caller of validate_config — the summary screen included. So an
# empty value before the disks phase is the normal state of a fresh encrypted
# install, and demanding it here rejected every such install at the summary
# with no way forward. The check now keys on the state that proves the plan
# already ran: a mapper root.
_valid_base
LUKS_ENABLED="yes"
LUKS_PARTITION=""
ROOT_PARTITION=""
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "a fresh LUKS install is not rejected before the disks phase" "0" "${rc}"

_valid_base
LUKS_ENABLED="yes"
LUKS_PARTITION=""
ROOT_PARTITION="/dev/mapper/cryptroot"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "LUKS with a mapper root but no container partition rejected" "1" "${rc}"
assert_contains "message names LUKS_PARTITION" "LUKS_PARTITION" "${out}"

_valid_base
LUKS_ENABLED="no"
LUKS_ALLOW_DISCARDS="yes"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "discard without encryption rejected" "1" "${rc}"
assert_contains "message names LUKS_ALLOW_DISCARDS" "LUKS_ALLOW_DISCARDS" "${out}"

_valid_base
LUKS_ALLOW_DISCARDS="maybe"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "bad LUKS_ALLOW_DISCARDS rejected" "1" "${rc}"
LUKS_ALLOW_DISCARDS="no"

_valid_base
LUKS_ENABLED="yes"
PARTITION_SCHEME="manual"
LUKS_PARTITION="/dev/sda2"
out=$(validate_config 2>&1) && rc=0 || rc=$?
assert_eq "LUKS + manual partitioning rejected" "1" "${rc}"
assert_contains "message explains manual is unsupported" "manual partitioning" "${out}"

echo ""
echo "=== Config plumbing ==="

for var in LUKS_ENABLED LUKS_PARTITION LUKS_ALLOW_DISCARDS; do
    found=0
    for known in "${CONFIG_VARS[@]}"; do
        [[ "${known}" == "${var}" ]] && found=1 && break
    done
    assert_eq "${var} is in CONFIG_VARS" "1" "${found}"
done

# The passphrase must NOT be persisted — config_save would write it to disk.
found=0
for known in "${CONFIG_VARS[@]}"; do
    [[ "${known}" == *PASSPHRASE* ]] && found=1
done
assert_eq "no passphrase variable in CONFIG_VARS" "0" "${found}"

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
