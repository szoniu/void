#!/usr/bin/env bash
# disk.sh — Two-phase disk operations (plan -> execute), UUID persistence
# Uses sfdisk (util-linux) for atomic GPT partitioning
source "${LIB_DIR}/protection.sh"

# Action queue for two-phase disk operations
declare -ga DISK_ACTIONS=()
declare -ga DISK_STDIN=()
# Parallel to DISK_STDIN: 1 marks a payload that must never be logged or
# placed on a command line (LUKS passphrase).
declare -ga DISK_SECRET=()

# --- Phase 1: Planning ---

# disk_plan_reset — Clear the action queue
disk_plan_reset() {
    DISK_ACTIONS=()
    DISK_STDIN=()
    DISK_SECRET=()
}

# disk_plan_add — Add an action to the queue (no stdin)
# Usage: disk_plan_add "description" command [args...]
disk_plan_add() {
    local desc="$1"
    shift
    local cmd
    cmd=$(printf '%q ' "$@")
    DISK_ACTIONS+=("${desc}|||${cmd}")
    DISK_STDIN+=("")
    DISK_SECRET+=("0")
}

# disk_plan_add_stdin — Add an action with stdin data
# Usage: disk_plan_add_stdin "description" "stdin_data" command [args...]
disk_plan_add_stdin() {
    local desc="$1" stdin="$2"
    shift 2
    local cmd
    cmd=$(printf '%q ' "$@")
    DISK_ACTIONS+=("${desc}|||${cmd}")
    DISK_STDIN+=("${stdin}")
    DISK_SECRET+=("0")
}

# disk_plan_add_secret_stdin — Same, but the stdin payload is a secret.
# Two things change for secrets: disk_plan_show masks the payload instead of
# writing it to the log, and disk_execute_plan passes it through the
# environment rather than interpolating it into a `bash -c` string (which
# would expose a LUKS passphrase in `ps`).
disk_plan_add_secret_stdin() {
    local desc="$1" stdin="$2"
    shift 2
    local cmd
    cmd=$(printf '%q ' "$@")
    DISK_ACTIONS+=("${desc}|||${cmd}")
    DISK_STDIN+=("${stdin}")
    DISK_SECRET+=("1")
}

# disk_plan_show — Display planned actions
disk_plan_show() {
    local i
    einfo "Planned disk operations:"
    for (( i = 0; i < ${#DISK_ACTIONS[@]}; i++ )); do
        local desc="${DISK_ACTIONS[$i]%%|||*}"
        einfo "  $((i + 1)). ${desc}"
        if [[ -n "${DISK_STDIN[$i]:-}" ]]; then
            if [[ "${DISK_SECRET[$i]:-0}" == "1" ]]; then
                elog "    stdin: (secret withheld)"
            else
                elog "    stdin script: ${DISK_STDIN[$i]}"
            fi
        fi
    done
}

# disk_plan_auto — Generate auto-partitioning plan using sfdisk
disk_plan_auto() {
    local disk="${TARGET_DISK}"
    local fs="${FILESYSTEM:-ext4}"
    local swap_type="${SWAP_TYPE:-zram}"
    local swap_size="${SWAP_SIZE_MIB:-${SWAP_DEFAULT_SIZE_MIB}}"

    disk_plan_reset

    # Build sfdisk script — single atomic operation for all partitions
    local sfdisk_script="label: gpt"$'\n'
    sfdisk_script+="start=1MiB, size=${ESP_SIZE_MIB}MiB, type=${GPT_TYPE_EFI}, name=ESP"$'\n'

    if [[ "${swap_type}" == "partition" ]]; then
        sfdisk_script+="size=${swap_size}MiB, type=${GPT_TYPE_SWAP}, name=swap"$'\n'
    fi

    # Root partition — no size= means remaining space
    sfdisk_script+="type=${GPT_TYPE_LINUX}, name=linux"$'\n'

    disk_plan_add_stdin "Create GPT partition table and partitions on ${disk}" \
        "${sfdisk_script}" \
        sfdisk --force --no-reread "${disk}"

    # Determine partition device names
    local part_prefix="${disk}"
    # Handle NVMe and other numbered device names
    if [[ "${disk}" =~ [0-9]$ ]]; then
        part_prefix="${disk}p"
    fi

    local part_num=1
    ESP_PARTITION="${part_prefix}${part_num}"
    disk_plan_add "Format ESP as FAT32" \
        mkfs.vfat -F 32 -n EFI "${ESP_PARTITION}"
    (( part_num++ ))

    if [[ "${swap_type}" == "partition" ]]; then
        SWAP_PARTITION="${part_prefix}${part_num}"
        disk_plan_add "Format swap partition" \
            mkswap -L swap "${SWAP_PARTITION}"
        (( part_num++ ))
    fi

    ROOT_PARTITION="${part_prefix}${part_num}"

    # LUKS: the partition itself becomes the container, and everything after
    # this point (mkfs, mount, fstab) works on /dev/mapper/<name> instead.
    if [[ "${LUKS_ENABLED:-no}" == "yes" ]]; then
        LUKS_PARTITION="${ROOT_PARTITION}"
        _plan_luks_setup "${LUKS_PARTITION}"
        ROOT_PARTITION="/dev/mapper/${LUKS_NAME:-cryptroot}"
        export LUKS_PARTITION
    fi

    case "${fs}" in
        ext4)
            disk_plan_add "Format root as ext4" \
                mkfs.ext4 -L void "${ROOT_PARTITION}"
            ;;
        btrfs)
            disk_plan_add "Format root as btrfs" \
                mkfs.btrfs -f -L void "${ROOT_PARTITION}"
            ;;
        xfs)
            disk_plan_add "Format root as XFS" \
                mkfs.xfs -f -L void "${ROOT_PARTITION}"
            ;;
    esac

    export ESP_PARTITION ROOT_PARTITION SWAP_PARTITION

    einfo "Auto-partition plan generated for ${disk}"
}

# --- LUKS helpers ---

# luks_prompt_passphrase — Ask for the passphrase twice and verify.
# Sets _LUKS_PASSPHRASE (a plain global, deliberately NOT in CONFIG_VARS:
# config_save would write it to disk, and a passphrase in a file defeats the
# point of encrypting the disk). A resumed run therefore asks again.
luks_prompt_passphrase() {
    local pass1 pass2

    while true; do
        pass1=$(dialog_passwordbox "LUKS Passphrase" \
            "Enter the passphrase for the encrypted root partition.\n\n\
You will type this at every boot. There is NO recovery if\n\
you forget it — the data is gone.") || return 1

        if [[ ${#pass1} -lt 8 ]]; then
            dialog_msgbox "Passphrase Too Short" \
                "Use at least 8 characters." || true
            continue
        fi

        pass2=$(dialog_passwordbox "Confirm Passphrase" \
            "Enter the same passphrase again:") || return 1

        if [[ "${pass1}" == "${pass2}" ]]; then
            break
        fi

        dialog_msgbox "Passphrases Differ" "The two entries did not match." || true
    done

    _LUKS_PASSPHRASE="${pass1}"
    return 0
}

# _plan_luks_setup — Queue LUKS container creation + open.
#
# Two details that are easy to get wrong:
#   - GRUB's LUKS2 support is limited (PBKDF2 only, not the default Argon2i),
#     so the container is created as LUKS1. GRUB must read the container
#     itself because /boot lives on the encrypted root.
#   - The passphrase is fed through stdin (`--key-file -`), never as an
#     argument, and the plan entry is marked secret so it stays out of the log.
#
# Idempotent for --resume: a partition that already holds a LUKS header is
# only opened, never re-formatted — re-formatting would destroy the data that
# resume is supposed to preserve.
_plan_luks_setup() {
    local part="$1"
    local name="${LUKS_NAME:-cryptroot}"
    local passphrase="${_LUKS_PASSPHRASE:-}"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        disk_plan_add "Set up LUKS encryption on ${part}" \
            bash -c "echo '[DRY-RUN] Would set up LUKS on ${part}'"
        return 0
    fi

    if [[ -z "${passphrase}" ]]; then
        # Reached when installing from a saved config (`--install`): the
        # config never carries the passphrase, so ask for it now.
        luks_prompt_passphrase || die "LUKS enabled but no passphrase given"
        passphrase="${_LUKS_PASSPHRASE}"
    fi

    local current_type=""
    current_type=$(blkid -s TYPE -o value "${part}" 2>/dev/null) || true

    local fresh_container=1
    if [[ "${current_type}" == "crypto_LUKS" ]]; then
        einfo "${part} already holds a LUKS header — will open, not re-format"
        fresh_container=0
    else
        disk_plan_add_secret_stdin "Set up LUKS encryption on ${part}" \
            "${passphrase}" \
            cryptsetup luksFormat --batch-mode --type luks1 --key-file - "${part}"
    fi

    disk_plan_add_secret_stdin "Open LUKS container as /dev/mapper/${name}" \
        "${passphrase}" \
        bash -c "if [ -b /dev/mapper/${name} ]; then echo 'already open'; else cryptsetup luksOpen --key-file - '${part}' '${name}'; fi"

    # Second key slot holding a random keyfile, so the installed system asks
    # for the passphrase once (GRUB) instead of twice (GRUB + initramfs).
    # Only for a container we just created: re-running this on a resume would
    # burn a new key slot on every attempt.
    if [[ ${fresh_container} -eq 1 ]]; then
        local keyfile="${LUKS_KEYFILE_STAGE:-/tmp/void-installer-luks.key}"
        disk_plan_add_secret_stdin "Add initramfs keyfile to the LUKS container" \
            "${passphrase}" \
            bash -c "umask 077 && dd if=/dev/urandom of='${keyfile}' bs=512 count=8 status=none && chmod 000 '${keyfile}' && cryptsetup luksAddKey --key-file - '${part}' '${keyfile}'"
    fi
}

# luks_open_for_resume — Open the LUKS container outside the planning path.
# Used by --resume and by the early mount in tui/progress.sh, where the disk
# plan never runs but the filesystem still has to be reachable.
luks_open_for_resume() {
    local part="${LUKS_PARTITION:-}"
    local name="${LUKS_NAME:-cryptroot}"

    [[ "${LUKS_ENABLED:-no}" == "yes" ]] || return 0
    [[ -b "${part}" ]] || return 1
    [[ -b "/dev/mapper/${name}" ]] && return 0

    local passphrase="${_LUKS_PASSPHRASE:-}"
    if [[ -z "${passphrase}" ]]; then
        # A resumed run has no passphrase in memory — the config deliberately
        # never stores it. Ask again rather than failing silently.
        passphrase=$(dialog_passwordbox "LUKS Passphrase" \
            "Enter the passphrase for the encrypted partition\n${part}:") || return 1
    fi

    _VOID_SECRET_STDIN="${passphrase}" \
        bash -c 'printf "%s" "${_VOID_SECRET_STDIN}" | cryptsetup luksOpen --key-file - "$1" "$2"' \
        -- "${part}" "${name}" || return 1

    einfo "Opened LUKS container ${part} as /dev/mapper/${name}"
    return 0
}

# luks_close — Close the container (used when unmounting the target).
luks_close() {
    local name="${LUKS_NAME:-cryptroot}"
    [[ -b "/dev/mapper/${name}" ]] || return 0
    cryptsetup luksClose "${name}" 2>/dev/null \
        || ewarn "Could not close LUKS container ${name}"
}

# --- Shrink helpers ---

# disk_get_free_space_mib — Get total free (unallocated) space on disk in MiB
# Returns 0 MiB if no free space or on error
disk_get_free_space_mib() {
    local disk="$1"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "${_DRY_RUN_FREE_SPACE_MIB:-0}"
        return 0
    fi

    local sectors sector_size total_free_sectors=0
    sector_size=$(blockdev --getss "${disk}" 2>/dev/null) || sector_size=512

    while IFS= read -r line; do
        local s
        s=$(echo "${line}" | awk 'NF>=3 && $3 ~ /^[0-9]+$/ {print $3}') || true
        if [[ -n "${s}" ]]; then
            (( total_free_sectors += s )) || true
        fi
    done < <(sfdisk --list-free "${disk}" 2>/dev/null)

    echo $(( total_free_sectors * sector_size / 1024 / 1024 ))
}

# disk_get_partition_size_mib — Get partition size in MiB
disk_get_partition_size_mib() {
    local part="$1"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "${_DRY_RUN_PART_SIZE_MIB:-0}"
        return 0
    fi

    local bytes
    bytes=$(lsblk -bno SIZE "${part}" 2>/dev/null | head -1) || bytes=0
    echo $(( bytes / 1024 / 1024 ))
}

# disk_get_partition_used_mib — Get used space on partition in MiB
# Supports ntfs, ext4, btrfs. Returns 0 on error or unsupported.
disk_get_partition_used_mib() {
    local part="$1" fstype="$2"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "${_DRY_RUN_PART_USED_MIB:-0}"
        return 0
    fi

    case "${fstype}" in
        ntfs)
            local info
            info=$(ntfsresize --info --force --no-action "${part}" 2>/dev/null) || { echo 0; return 0; }
            local bytes
            bytes=$(echo "${info}" | sed -n 's/.*resize at \([0-9]*\) bytes.*/\1/p' | head -1) || true
            if [[ -n "${bytes}" ]]; then
                echo $(( bytes / 1024 / 1024 ))
            else
                echo 0
            fi
            ;;
        ext4)
            local dump
            dump=$(dumpe2fs -h "${part}" 2>/dev/null) || { echo 0; return 0; }
            local block_count free_blocks block_size
            block_count=$(echo "${dump}" | sed -n 's/^Block count:[[:space:]]*//p' | head -1) || true
            free_blocks=$(echo "${dump}" | sed -n 's/^Free blocks:[[:space:]]*//p' | head -1) || true
            block_size=$(echo "${dump}" | sed -n 's/^Block size:[[:space:]]*//p' | head -1) || true
            if [[ -n "${block_count}" && -n "${free_blocks}" && -n "${block_size}" ]]; then
                echo $(( (block_count - free_blocks) * block_size / 1024 / 1024 ))
            else
                echo 0
            fi
            ;;
        btrfs)
            local tmpdir
            tmpdir=$(mktemp -d) || { echo 0; return 0; }
            if mount -o ro "${part}" "${tmpdir}" 2>/dev/null; then
                local used_bytes
                used_bytes=$(btrfs filesystem usage -b "${tmpdir}" 2>/dev/null \
                    | sed -n 's/^[[:space:]]*Used:[[:space:]]*//p' | head -1) || true
                umount "${tmpdir}" 2>/dev/null || true
                rmdir "${tmpdir}" 2>/dev/null || true
                if [[ -n "${used_bytes}" ]]; then
                    echo $(( used_bytes / 1024 / 1024 ))
                else
                    echo 0
                fi
            else
                rmdir "${tmpdir}" 2>/dev/null || true
                echo 0
            fi
            ;;
        *)
            echo 0
            ;;
    esac
}

# disk_can_shrink_fstype — Check if filesystem type can be shrunk
# Returns 0 (true) for ntfs/ext4/btrfs, 1 (false) otherwise
disk_can_shrink_fstype() {
    local fstype="$1"
    case "${fstype}" in
        ntfs|ext4|btrfs) return 0 ;;
        *) return 1 ;;
    esac
}

# disk_plan_shrink — Add shrink actions to DISK_ACTIONS[]
# Requires: SHRINK_PARTITION, SHRINK_PARTITION_FSTYPE, SHRINK_NEW_SIZE_MIB
disk_plan_shrink() {
    local part="${SHRINK_PARTITION}"
    local fstype="${SHRINK_PARTITION_FSTYPE}"
    local new_size="${SHRINK_NEW_SIZE_MIB}"
    local disk="${TARGET_DISK}"

    # Determine partition number from device path
    local part_num
    part_num=$(echo "${part}" | sed 's/.*[^0-9]\([0-9]*\)$/\1/') || true

    if [[ -z "${part_num}" ]]; then
        eerror "Cannot determine partition number from ${part}"
        return 1
    fi

    # Hard safety gate #1: never resize an encrypted volume. BitLocker can look
    # like plain ntfs to lsblk, so the fstype check below would let it through and
    # ntfsresize would operate on ciphertext. Same reasoning as the used-space
    # gate under it: this path is reachable from a hand-edited preset or an
    # inferred --resume config, without the wizard ever running.
    local _blp
    for _blp in ${BITLOCKER_PARTITIONS:-}; do
        if [[ "${part}" == "${_blp}" ]]; then
            eerror "Refusing to shrink ${part}: BitLocker-encrypted volume"
            eerror "No Linux tool can resize it — shrink it from Windows instead"
            return 1
        fi
    done

    # Hard safety gate #2, independent of the TUI shrink wizard: never shrink a
    # partition below the space it is actually using (+1 GiB margin). The
    # wizard normally enforces this, but disk_plan_shrink can also be reached
    # from a hand-edited preset or an inferred --resume config where the value
    # is untrusted — shrinking below used data destroys the filesystem.
    local used_mib margin=1024
    used_mib=$(disk_get_partition_used_mib "${part}" "${fstype}")
    if [[ "${used_mib}" =~ ^[0-9]+$ && "${used_mib}" -gt 0 ]] && \
       [[ "${new_size}" -lt $(( used_mib + margin )) ]]; then
        eerror "Refusing to shrink ${part}: requested ${new_size} MiB is below"
        eerror "used space ${used_mib} MiB + ${margin} MiB safety margin"
        return 1
    fi

    einfo "Planning shrink: ${part} (${fstype}) -> ${new_size} MiB"

    case "${fstype}" in
        ntfs)
            # Dry-run first: ntfsresize --no-action validates the target size
            # against the actual NTFS layout and fails harmlessly if it would
            # truncate data, before the destructive resize runs.
            disk_plan_add "Validate NTFS shrink on ${part} (dry-run)" \
                ntfsresize --no-action --force --size "${new_size}M" "${part}"
            disk_plan_add "Shrink NTFS filesystem on ${part}" \
                ntfsresize --force --size "${new_size}M" "${part}"
            ;;
        ext4)
            disk_plan_add "Check ext4 filesystem on ${part}" \
                e2fsck -f -y "${part}"
            disk_plan_add "Shrink ext4 filesystem on ${part}" \
                resize2fs "${part}" "${new_size}M"
            ;;
        btrfs)
            disk_plan_add "Shrink btrfs filesystem on ${part}" \
                bash -c "tmp=\$(mktemp -d /tmp/void-shrink-XXXXXX) && mount ${part} \${tmp} && { btrfs filesystem resize ${new_size}M \${tmp}; rc=\$?; umount \${tmp}; rmdir \${tmp}; exit \${rc}; }"
            ;;
    esac

    # Resize partition table entry
    disk_plan_add_stdin "Resize partition table entry ${part_num} on ${disk}" \
        ",${new_size}MiB"$'\n' \
        sfdisk --force --no-reread -N "${part_num}" "${disk}"

    # Re-read partition table (partprobe preferred, blockdev as fallback)
    if command -v partprobe &>/dev/null; then
        disk_plan_add "Re-read partition table on ${disk}" \
            partprobe "${disk}"
    else
        disk_plan_add "Re-read partition table on ${disk}" \
            blockdev --rereadpt "${disk}"
    fi
}

# disk_plan_dualboot — Generate dual-boot partitioning plan
disk_plan_dualboot() {
    local disk="${TARGET_DISK}"
    local fs="${FILESYSTEM:-ext4}"

    disk_plan_reset

    # Shrink existing partition first if requested
    if [[ -n "${SHRINK_PARTITION:-}" ]]; then
        disk_plan_shrink
    fi

    # ESP is reused, never formatted
    einfo "Reusing existing ESP: ${ESP_PARTITION}"

    if [[ -z "${ROOT_PARTITION:-}" ]]; then
        # Need to create root partition in free space using sfdisk --append
        disk_plan_add_stdin "Create root partition in free space" \
            "type=${GPT_TYPE_LINUX}, name=linux"$'\n' \
            sfdisk --append --force --no-reread "${disk}"

        # Determine the new partition's number. Use the HIGHEST existing
        # partition number + 1 (not a count — partition numbers can be
        # non-contiguous, e.g. p1+p3). lsblk is robust under `set -o pipefail`
        # (awk always prints an integer); the previous `sfdisk|grep -c`
        # collapsed to 0 on the pipefail/no-match path, which made
        # ROOT_PARTITION resolve to partition 1 — typically the ESP — and a
        # subsequent mkfs would have destroyed the existing boot partition.
        local disk_base max_num next_part_num
        disk_base="$(basename "${disk}")"
        # `|| max_num=0`: lsblk|awk under `set -o pipefail` (or a missing lsblk)
        # must not abort the installer here — fall back to 0 so the rescan in
        # disk_execute_plan corrects the number afterwards.
        max_num=$(lsblk -rno NAME,TYPE "${disk}" 2>/dev/null \
            | awk -v d="${disk_base}" '
                $2=="part" {
                    n=$1; sub("^" d "p?", "", n);
                    if (n ~ /^[0-9]+$/ && n+0 > m) m=n+0
                }
                END { print m+0 }') || max_num=0
        [[ "${max_num}" =~ ^[0-9]+$ ]] || max_num=0
        next_part_num=$(( max_num + 1 ))
        local part_prefix="${disk}"
        [[ "${disk}" =~ [0-9]$ ]] && part_prefix="${disk}p"
        ROOT_PARTITION="${part_prefix}${next_part_num}"
        # disk_execute_plan re-scans and corrects ROOT_PARTITION afterwards if
        # sfdisk --append assigned a different number than predicted here.
    fi

    # LUKS goes between partitioning and mkfs here too: the filesystem is
    # created inside the container, not on the bare partition.
    if [[ "${LUKS_ENABLED:-no}" == "yes" ]]; then
        LUKS_PARTITION="${ROOT_PARTITION}"
        _plan_luks_setup "${LUKS_PARTITION}"
        ROOT_PARTITION="/dev/mapper/${LUKS_NAME:-cryptroot}"
        export LUKS_PARTITION
    fi

    # Format root
    case "${fs}" in
        ext4)
            disk_plan_add "Format root as ext4" \
                mkfs.ext4 -L void "${ROOT_PARTITION}"
            ;;
        btrfs)
            disk_plan_add "Format root as btrfs" \
                mkfs.btrfs -f -L void "${ROOT_PARTITION}"
            ;;
        xfs)
            disk_plan_add "Format root as XFS" \
                mkfs.xfs -f -L void "${ROOT_PARTITION}"
            ;;
    esac

    export ROOT_PARTITION
    einfo "Dual-boot plan generated"
}

# --- Phase 2: Execution ---

# cleanup_target_disk — Unmount all partitions on target disk and deactivate swap
# Required before repartitioning (existing partitions may block sfdisk)
cleanup_target_disk() {
    local disk="${TARGET_DISK}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would cleanup ${disk}"
        return 0
    fi

    einfo "Cleaning up ${disk} (unmounting partitions, deactivating swap)..."

    # Deactivate any swap partitions on this disk
    local swap_part
    while IFS= read -r swap_part; do
        [[ -z "${swap_part}" ]] && continue
        swapoff "${swap_part}" 2>/dev/null && einfo "Deactivated swap: ${swap_part}" || true
    done < <(awk -v disk="${disk}" 'NR>1 && $1 ~ "^"disk"[p]?[0-9]" {print $1}' /proc/swaps 2>/dev/null)

    # Unmount all partitions on this disk (reverse order for nested mounts)
    local -a mounts
    readarray -t mounts < <(awk -v disk="${disk}" '$1 ~ "^"disk"[p]?[0-9]" {print $2}' /proc/mounts 2>/dev/null | sort -r)

    local mnt
    for mnt in "${mounts[@]}"; do
        [[ -z "${mnt}" ]] && continue
        umount -l "${mnt}" 2>/dev/null && einfo "Unmounted: ${mnt}" || true
    done

    # Close LUKS containers backed by this disk
    local _luks_name="${LUKS_NAME:-cryptroot}"
    if command -v cryptsetup &>/dev/null && [[ -b "/dev/mapper/${_luks_name}" ]]; then
        local backing
        backing=$(cryptsetup status "${_luks_name}" 2>/dev/null | awk '/device:/ {print $2}') || true
        if [[ "${backing}" == "${disk}"* ]]; then
            ewarn "Closing LUKS on ${_luks_name}"
            cryptsetup close "${_luks_name}" 2>/dev/null || true
        fi
    fi

    einfo "Cleanup of ${disk} complete"
}

# wait_for_block_device — wait until a device node actually exists
#
# udev creates nodes asynchronously after partprobe, so "the partition table is
# written" and "the device node is usable" are two different moments. Returns 0
# as soon as the node is there, non-zero if it never shows up within `timeout`
# seconds (default 10) — so the caller can abort instead of formatting a path
# that does not exist.
#
# udevadm is not on every live medium; the [[ -b ]] loop works without it, which
# is why the settle call is tolerant and doubles as the delay when present.
wait_for_block_device() {
    local dev="$1"
    local timeout="${2:-10}"
    local waited=0

    [[ -z "${dev}" ]] && return 0

    while (( waited < timeout )); do
        [[ -b "${dev}" ]] && return 0
        # settle first (it returns as soon as the queue drains), re-check, and
        # only then spend a second. Using settle AS the delay looked tidier but
        # made the timeout meaningless: with an empty udev queue it returns
        # instantly, so the whole loop burned through in microseconds and the
        # helper degenerated into the very race it exists to remove.
        udevadm settle --timeout=1 >/dev/null 2>&1 || true
        [[ -b "${dev}" ]] && return 0
        sleep 1
        (( waited++ )) || true
    done

    [[ -b "${dev}" ]]
}

# _reread_partition_table — make the kernel pick up a freshly written table
_reread_partition_table() {
    if command -v partprobe &>/dev/null; then
        partprobe "${TARGET_DISK}" 2>/dev/null || true
    else
        blockdev --rereadpt "${TARGET_DISK}" 2>/dev/null || true
    fi
}

# _wait_for_planned_partitions — block until every partition in the plan exists
#
# Split out of disk_execute_plan so it can be tested for real: the caller runs
# only under DRY_RUN=0, where exercising it in place would mean letting sfdisk
# and mkfs loose on a device. Review found the original assertions were greps
# over `declare -f`, which passed even after the loop was narrowed to the ESP
# alone — i.e. exactly the regression this code exists to prevent.
_wait_for_planned_partitions() {
    local _part
    for _part in "${ESP_PARTITION:-}" "${BOOT_PARTITION:-}" "${ROOT_PARTITION:-}" \
                 "${SWAP_PARTITION:-}" "${LUKS_PARTITION:-}"; do
        [[ -z "${_part}" ]] && continue
        wait_for_block_device "${_part}" && continue

        # Dual-boot is the one case where a missing node is expected rather
        # than fatal: `sfdisk --append` may hand out a different number than
        # planned, and disk_execute_plan detects the real one right after.
        if [[ "${PARTITION_SCHEME:-}" == "dual-boot" && "${_part}" == "${ROOT_PARTITION:-}" ]]; then
            ewarn "Partition ${_part} did not appear — will try to detect the actual one below"
            continue
        fi
        die "Partition ${_part} did not appear after partprobe — the kernel has not picked up the new partition table. The next step would operate on a device that does not exist."
    done
}

# disk_execute_plan — Execute all planned disk operations
disk_execute_plan() {
    if [[ ${#DISK_ACTIONS[@]} -eq 0 ]]; then
        # Generate plan based on scheme
        case "${PARTITION_SCHEME:-auto}" in
            auto)      disk_plan_auto ;;
            dual-boot) disk_plan_dualboot ;;
            manual)
                einfo "Manual partitioning — no automated plan"
                return 0
                ;;
        esac
    fi

    # Clean up any leftover mounts from previous installation attempts
    cleanup_target_disk

    disk_plan_show

    local i
    for (( i = 0; i < ${#DISK_ACTIONS[@]}; i++ )); do
        local entry="${DISK_ACTIONS[$i]}"
        local desc="${entry%%|||*}"
        local cmd="${entry#*|||}"
        local stdin_data="${DISK_STDIN[$i]:-}"

        einfo "[$((i + 1))/${#DISK_ACTIONS[@]}] ${desc}"

        if [[ -n "${stdin_data}" ]]; then
            if [[ "${DISK_SECRET[$i]:-0}" == "1" ]]; then
                # Secret payload (LUKS passphrase): goes through the
                # environment, never the command line — `ps` shows argv to
                # every user, /proc/PID/environ only to root.
                _VOID_SECRET_STDIN="${stdin_data}" \
                    try "${desc}" bash -c 'printf "%s" "${_VOID_SECRET_STDIN}" | '"${cmd}"
            else
                try "${desc}" bash -c "printf '%s' $(printf '%q' "${stdin_data}") | ${cmd}"
            fi
        else
            try "${desc}" bash -c "${cmd}"
        fi

        # The race is HERE, not after the loop. sfdisk writes the table and the
        # very next action (mkfs.vfat on the ESP, cryptsetup luksFormat) opens a
        # node udev may not have created yet — both are entries in this same
        # DISK_ACTIONS list. Waiting once the whole plan has run, which is what
        # the old `sleep 2` did and what the first version of this fix kept
        # doing, arrives after the formatting it was meant to protect.
        if [[ "${DRY_RUN}" != "1" && "${cmd}" == *sfdisk* ]]; then
            _reread_partition_table
            _wait_for_planned_partitions
        fi
    done

    # Second pass, after every action: dual-boot renumbering (below) needs a
    # settled table, and a plan that never touched sfdisk still has to see nodes.
    if [[ "${DRY_RUN}" != "1" ]]; then
        _reread_partition_table
        _wait_for_planned_partitions

        # Verify ROOT_PARTITION exists for dual-boot (sfdisk --append may assign different number)
        if [[ "${PARTITION_SCHEME:-}" == "dual-boot" && -n "${ROOT_PARTITION:-}" ]]; then
            if [[ ! -b "${ROOT_PARTITION}" ]]; then
                ewarn "Expected partition ${ROOT_PARTITION} not found, rescanning..."
                local actual_last
                actual_last=$(sfdisk --dump "${TARGET_DISK}" 2>/dev/null \
                    | grep "^${TARGET_DISK}" | tail -1 | awk '{print $1}') || true
                if [[ -n "${actual_last}" && -b "${actual_last}" ]]; then
                    ewarn "Using detected partition: ${actual_last} (instead of ${ROOT_PARTITION})"
                    ROOT_PARTITION="${actual_last}"
                    export ROOT_PARTITION
                else
                    ewarn "Could not detect root partition — manual verification may be needed"
                fi
            fi
        fi
    fi

    # After auto partitioning, any OS found by the pre-install hardware scan is
    # gone — every partition was wiped and reformatted. Clear DETECTED_OSES so
    # _verify_grub_config does not emit false-positive "missing OS" warnings
    # about systems the user deliberately erased.
    if [[ "${PARTITION_SCHEME:-auto}" == "auto" && "${DRY_RUN:-0}" != "1" ]]; then
        if [[ -n "${DETECTED_OSES_SERIALIZED:-}" || "${WINDOWS_DETECTED:-0}" != "0" || "${LINUX_DETECTED:-0}" != "0" ]]; then
            einfo "Clearing pre-wipe OS detection (auto scheme erases all)"
            declare -gA DETECTED_OSES=()
            WINDOWS_DETECTED=0
            LINUX_DETECTED=0
            DETECTED_OSES_SERIALIZED=""
            # BitLocker state describes partitions that no longer exist after the
            # wipe; leaving it set would keep the encrypted-Windows warning in the
            # summary and in the saved config for a disk that is now empty.
            BITLOCKER_DETECTED=0
            BITLOCKER_PARTITIONS=""
            export WINDOWS_DETECTED LINUX_DETECTED DETECTED_OSES_SERIALIZED
            export BITLOCKER_DETECTED BITLOCKER_PARTITIONS
        fi
    fi

    einfo "All disk operations completed"
}

# --- Mount/unmount ---

# mount_filesystems — Mount root, ESP, and btrfs subvolumes
mount_filesystems() {
    einfo "Mounting filesystems..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would mount filesystems"
        return 0
    fi

    mkdir -p "${MOUNTPOINT}"

    local fs="${FILESYSTEM:-ext4}"

    if [[ "${fs}" == "btrfs" ]]; then
        # Subvolume CREATION only makes sense on a fresh filesystem, so it stays
        # gated on root not being mounted yet. Subvolume MOUNTING must happen
        # unconditionally — see the loop further down.
        if ! mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
            # Mount btrfs top level to create subvolumes
            try "Mounting btrfs root" mount "${ROOT_PARTITION}" "${MOUNTPOINT}"

            if [[ -n "${BTRFS_SUBVOLUMES:-}" ]]; then
                local IFS=':'
                local -a parts
                read -ra parts <<< "${BTRFS_SUBVOLUMES}"
                local idx
                for (( idx = 0; idx < ${#parts[@]}; idx += 2 )); do
                    local subvol="${parts[$idx]}"
                    if ! btrfs subvolume list "${MOUNTPOINT}" 2>/dev/null | grep -q " ${subvol}$"; then
                        try "Creating btrfs subvolume ${subvol}" \
                            btrfs subvolume create "${MOUNTPOINT}/${subvol}"
                    fi
                done
            fi

            # Unmount the top level and remount @ as root
            umount "${MOUNTPOINT}"

            try "Mounting @ subvolume" \
                mount -o subvol=@,compress=zstd,noatime "${ROOT_PARTITION}" "${MOUNTPOINT}"
        fi

        # Mount the non-@ subvolumes ALWAYS — including the --resume path where
        # root came up already mounted. Skipping this let a resumed `users`
        # phase run with @home unmounted: `useradd -m` wrote the home directory
        # into @ instead, and at boot fstab mounted an empty @home over it, so
        # logins failed (SDDM/GDM bounced, SSH could not chdir to home).
        # Caught on a real HP ProBook 450 G8 resume in the Gentoo installer.
        if [[ -n "${BTRFS_SUBVOLUMES:-}" ]]; then
            local IFS=':'
            local -a parts
            read -ra parts <<< "${BTRFS_SUBVOLUMES}"
            local idx
            for (( idx = 0; idx < ${#parts[@]}; idx += 2 )); do
                local subvol="${parts[$idx]}"
                local mpoint="${parts[$((idx + 1))]}"
                [[ "${subvol}" == "@" ]] && continue
                mkdir -p "${MOUNTPOINT}${mpoint}"
                if ! mountpoint -q "${MOUNTPOINT}${mpoint}" 2>/dev/null; then
                    try "Mounting subvolume ${subvol} at ${mpoint}" \
                        mount -o "subvol=${subvol},compress=zstd,noatime" \
                        "${ROOT_PARTITION}" "${MOUNTPOINT}${mpoint}"
                fi
            done
        fi
    else
        # Simple mount for ext4/xfs — no-op when already mounted (resume)
        if ! mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
            try "Mounting root filesystem" mount "${ROOT_PARTITION}" "${MOUNTPOINT}"
        fi
    fi

    # Mount ESP (idempotent — the resume path may already have it)
    local esp_mount="${MOUNTPOINT}/boot/efi"
    mkdir -p "${esp_mount}"
    if ! mountpoint -q "${esp_mount}" 2>/dev/null; then
        try "Mounting ESP" mount "${ESP_PARTITION}" "${esp_mount}"
    fi

    # Activate swap if partition
    if [[ "${SWAP_TYPE:-}" == "partition" && -n "${SWAP_PARTITION:-}" ]]; then
        try "Activating swap" swapon "${SWAP_PARTITION}"
    fi

    einfo "Filesystems mounted at ${MOUNTPOINT}"
}

# unmount_filesystems — Unmount everything in reverse order
unmount_filesystems() {
    einfo "Unmounting filesystems..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would unmount filesystems"
        return 0
    fi

    # Deactivate swap
    if [[ "${SWAP_TYPE:-}" == "partition" && -n "${SWAP_PARTITION:-}" ]]; then
        swapoff "${SWAP_PARTITION}" 2>/dev/null || true
    fi

    # Unmount in reverse order — find all mounts under MOUNTPOINT
    local -a mounts
    readarray -t mounts < <(awk -v mp="${MOUNTPOINT}" '$2 == mp || $2 ~ "^"mp"/" {print $2}' /proc/mounts 2>/dev/null | sort -r)

    local mnt
    for mnt in "${mounts[@]}"; do
        umount -l "${mnt}" 2>/dev/null || true
    done

    # Close the LUKS container last — it can only go once nothing is mounted
    # on top of it.
    if [[ "${LUKS_ENABLED:-no}" == "yes" ]]; then
        luks_close
    fi

    einfo "Filesystems unmounted"
}

# get_uuid — Get UUID of a partition
get_uuid() {
    local partition="$1"
    blkid -s UUID -o value "${partition}" 2>/dev/null
}

# get_partuuid — Get PARTUUID of a partition
get_partuuid() {
    local partition="$1"
    blkid -s PARTUUID -o value "${partition}" 2>/dev/null
}
