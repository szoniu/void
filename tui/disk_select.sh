#!/usr/bin/env bash
# tui/disk_select.sh — Disk selection + partition scheme
source "${LIB_DIR}/protection.sh"

# _get_partition_info_for_dialog — Build rich partition list with OS info
# Args: disk esp_partition
# Populates: part_items[] (tag, description pairs) and DANGEROUS_PARTITIONS[]
_get_partition_info_for_dialog() {
    local disk="$1" esp_partition="${2:-}"
    part_items=()
    declare -gA DANGEROUS_PARTITIONS=()

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local pname psize pfstype plabel
        read -r pname psize pfstype plabel <<< "${line}"
        local pdev="/dev/${pname}"

        # Skip the disk device itself and ESP
        [[ "${pdev}" == "${disk}" ]] && continue
        [[ "${pdev}" == "${esp_partition}" ]] && continue

        # Build description with filesystem and label info
        local desc="${psize}"
        [[ -n "${pfstype}" ]] && desc+=" ${pfstype}"
        [[ -n "${plabel}" ]] && desc+=" \"${plabel}\""

        # Add detected OS info
        if [[ -n "${DETECTED_OSES[${pdev}]:-}" ]]; then
            desc+=" [${DETECTED_OSES[${pdev}]}]"
            DANGEROUS_PARTITIONS["${pdev}"]="${DETECTED_OSES[${pdev}]}"
        fi

        part_items+=("${pdev}" "${desc}")
    done < <(lsblk -lno NAME,SIZE,FSTYPE,LABEL "${disk}" 2>/dev/null | tail -n +2)
}

# _shrink_wizard — Interactive wizard for shrinking a partition to make room for Void
# Sets: SHRINK_PARTITION, SHRINK_PARTITION_FSTYPE, SHRINK_NEW_SIZE_MIB
# Returns: TUI_NEXT on success, TUI_BACK on cancel
_shrink_wizard() {
    local disk="$1" esp_partition="${2:-}"

    # Step 1: Warning about backup
    dialog_msgbox "No Free Space" \
        "There is not enough free space on ${disk} to create a Void partition.\n\n\
To proceed, an existing partition must be shrunk.\n\n\
!!! IMPORTANT: BACK UP YOUR DATA FIRST !!!\n\n\
Shrinking a partition carries a risk of data loss.\n\
Make sure you have a full backup before continuing." || true

    # Step 2: Build list of shrinkable partitions
    local -a shrink_items=()
    local -a shrink_parts=()
    local -a shrink_fstypes=()

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local pname psize pfstype plabel
        read -r pname psize pfstype plabel <<< "${line}"
        local pdev="/dev/${pname}"

        # Skip disk itself, ESP, and unshrinkable filesystems
        [[ "${pdev}" == "${disk}" ]] && continue
        [[ "${pdev}" == "${esp_partition}" ]] && continue
        [[ -z "${pfstype}" ]] && continue

        # A BitLocker volume can report itself as plain `ntfs` — that is exactly
        # why detect_bitlocker() checks the volume signature and not just the
        # fstype string. Without this the partition passes disk_can_shrink_fstype,
        # lands on the shrink list and ntfsresize gets pointed at ciphertext.
        # The fstype does not know; detect_bitlocker() already worked it out.
        local _blp _skip_bl=0
        for _blp in ${BITLOCKER_PARTITIONS:-}; do
            [[ "${pdev}" == "${_blp}" ]] && _skip_bl=1 && break
        done
        [[ ${_skip_bl} -eq 1 ]] && continue

        disk_can_shrink_fstype "${pfstype}" || continue

        # Check resize tools available (skip if missing)
        case "${pfstype}" in
            ntfs) command -v ntfsresize >/dev/null 2>&1 || continue ;;
            ext4) command -v resize2fs >/dev/null 2>&1 || continue ;;
            btrfs) command -v btrfs >/dev/null 2>&1 || continue ;;
        esac

        local desc="${psize} ${pfstype}"
        [[ -n "${plabel}" ]] && desc+=" \"${plabel}\""
        if [[ -n "${DETECTED_OSES[${pdev}]:-}" ]]; then
            desc+=" [${DETECTED_OSES[${pdev}]}]"
        fi

        # First item pre-selected, rest off
        local on_off="off"
        [[ ${#shrink_items[@]} -eq 0 ]] && on_off="on"
        shrink_items+=("${pdev}" "${desc}" "${on_off}")
        shrink_parts+=("${pdev}")
        shrink_fstypes+=("${pfstype}")
    done < <(lsblk -lno NAME,SIZE,FSTYPE,LABEL "${disk}" 2>/dev/null | tail -n +2)

    if [[ ${#shrink_items[@]} -eq 0 ]]; then
        # APFS/HFS+ deserve their own message: no Linux tool can resize an
        # APFS container, so "unsupported filesystem" would send the user
        # looking for a package that does not exist.
        local has_macos_fs=0
        local has_bitlocker_fs=0
        local mline mfstype
        while IFS= read -r mline; do
            mfstype=$(awk '{print $3}' <<< "${mline}")
            if declare -F apple_fstype_is_macos >/dev/null && \
               [[ -n "${mfstype}" ]] && apple_fstype_is_macos "${mfstype}"; then
                has_macos_fs=1
                break
            fi
            if declare -F bitlocker_fstype_is_encrypted >/dev/null && \
               [[ -n "${mfstype}" ]] && bitlocker_fstype_is_encrypted "${mfstype}"; then
                has_bitlocker_fs=1
            fi
        done < <(lsblk -lno NAME,SIZE,FSTYPE "${disk}" 2>/dev/null | tail -n +2)

        # FSTYPE alone misses the case the signature fallback exists for: with an
        # old libblkid the encrypted partition reports NO fstype, so the loop
        # above cannot see it and the user would get the generic "unsupported
        # filesystem" — in exactly the scenario the extra detection path was
        # written to cover. detect_bitlocker() already worked this out, so use
        # its result and treat fstype as the secondary signal.
        local blp
        for blp in ${BITLOCKER_PARTITIONS:-}; do
            [[ "${blp}" == "${disk}"* ]] && has_bitlocker_fs=1 && break
        done

        # BitLocker gets its own message for the same reason APFS does: the
        # generic "unsupported filesystem" sends the user hunting for a tool that
        # does not exist. ntfsresize cannot touch an encrypted volume — the fix
        # is on the Windows side, and it is a suspend/decrypt, not a package.
        if [[ ${has_macos_fs} -eq 0 && ${has_bitlocker_fs} -eq 1 ]]; then
            dialog_msgbox "Cannot Shrink a BitLocker Partition" \
                "${disk} holds a BitLocker-ENCRYPTED Windows partition and\n\
there is not enough free space for Void.\n\n\
No Linux tool can resize an encrypted volume — ntfsresize\n\
sees ciphertext, not a filesystem.\n\n\
Do this instead, in Windows:\n\
  1. Boot Windows\n\
  2. Disk Management -> shrink the volume there\n\
     (BitLocker stays on; Windows resizes it itself)\n\
  3. Leave at least 30 GiB of FREE space (do not create\n\
     a partition there — the installer will)\n\n\
Suspending or decrypting BitLocker also works, but shrinking\n\
from Windows is enough and keeps the disk encrypted.\n\n\
IMPORTANT: back up your recovery key before repartitioning."
            return "${TUI_BACK}"
        fi

        if [[ ${has_macos_fs} -eq 1 ]]; then
            dialog_msgbox "Cannot Shrink macOS Partition" \
                "${disk} holds an APFS/HFS+ (macOS) partition and there is not\n\
enough free space for Void.\n\n\
APFS CANNOT be resized from Linux — no tool exists.\n\n\
Do this instead:\n\
  1. Reboot into macOS\n\
  2. Disk Utility -> select the container -> Partition\n\
     (or: diskutil apfs resizeContainer diskXsY <newsize>)\n\
  3. Leave at least 30 GiB of FREE space (do not create\n\
     a partition there — the installer will)\n\
  4. Boot this installer again\n\n\
Back up with Time Machine first."
        else
            dialog_msgbox "Cannot Shrink" \
                "No shrinkable partitions found on ${disk}.\n\n\
Supported filesystems: NTFS, ext4, btrfs.\n\
XFS cannot be shrunk.\n\n\
Please use manual partitioning instead."
        fi
        return "${TUI_BACK}"
    fi

    # Step 3: Select partition to shrink
    local selected_part
    selected_part=$(dialog_radiolist "Select Partition to Shrink" "${shrink_items[@]}") \
        || return "${TUI_BACK}"

    # Find fstype for selected partition
    local selected_fstype=""
    local i
    for (( i = 0; i < ${#shrink_parts[@]}; i++ )); do
        if [[ "${shrink_parts[$i]}" == "${selected_part}" ]]; then
            selected_fstype="${shrink_fstypes[$i]}"
            break
        fi
    done

    # Step 4: OS warning
    if [[ -n "${DETECTED_OSES[${selected_part}]:-}" ]]; then
        local os_name="${DETECTED_OSES[${selected_part}]}"
        dialog_yesno "WARNING: OS Detected" \
            "The partition ${selected_part} contains:\n\n\
  ${os_name}\n\n\
Shrinking this partition will resize the filesystem.\n\
Data should be preserved, but there is always a risk.\n\n\
Are you sure you want to shrink this partition?" \
            || return "${TUI_BACK}"
    fi

    # NTFS-specific: warn about hibernation/fast startup
    if [[ "${selected_fstype}" == "ntfs" ]]; then
        dialog_msgbox "NTFS Warning" \
            "Before shrinking an NTFS partition:\n\n\
1. Disable Windows Fast Startup\n\
   (Settings > Power > Fast Startup > OFF)\n\
2. Disable hibernation (powercfg /h off)\n\
3. Perform a clean shutdown (not hibernate)\n\
4. Run chkdsk on Windows first\n\n\
Failure to do so may cause data loss." || true
    fi

    # Step 5: Get sizes
    local total_mib used_mib
    total_mib=$(disk_get_partition_size_mib "${selected_part}")
    used_mib=$(disk_get_partition_used_mib "${selected_part}" "${selected_fstype}")

    # Safety margin: 1 GiB above used
    local safety_margin=1024
    local min_part_size=$(( used_mib + safety_margin ))

    if [[ ${total_mib} -le ${min_part_size} ]]; then
        dialog_msgbox "Cannot Shrink" \
            "Partition ${selected_part} cannot be shrunk further.\n\n\
Total: ${total_mib} MiB\n\
Used:  ${used_mib} MiB\n\
Minimum (used + 1 GiB safety): ${min_part_size} MiB\n\n\
There is not enough room to free space for Void."
        return "${TUI_BACK}"
    fi

    local max_void_mib=$(( total_mib - min_part_size ))

    # Default: half available or 20 GiB, whichever is smaller
    local default_void=20480
    if [[ $(( max_void_mib / 2 )) -lt ${default_void} ]]; then
        default_void=$(( max_void_mib / 2 ))
    fi
    # Clamp to minimum
    if [[ ${default_void} -lt ${VOID_MIN_SIZE_MIB} ]]; then
        default_void=${VOID_MIN_SIZE_MIB}
    fi

    # Step 6: Ask for Void size
    local void_size_mib
    while true; do
        void_size_mib=$(dialog_inputbox "Space for Void (MiB)" \
            "How much space to free for Void?\n\n\
Partition: ${selected_part} (${selected_fstype})\n\
Total:     ${total_mib} MiB\n\
Used:      ${used_mib} MiB\n\
Maximum:   ${max_void_mib} MiB\n\
Minimum:   ${VOID_MIN_SIZE_MIB} MiB (10 GiB)\n\n\
Enter size in MiB:" \
            "${default_void}") || return "${TUI_BACK}"

        # Validate input is a number
        if [[ ! "${void_size_mib}" =~ ^[0-9]+$ ]]; then
            dialog_msgbox "Invalid Input" "Please enter a number (MiB)." || true
            continue
        fi

        if [[ ${void_size_mib} -lt ${VOID_MIN_SIZE_MIB} ]]; then
            dialog_msgbox "Too Small" \
                "Minimum size for Void is ${VOID_MIN_SIZE_MIB} MiB (10 GiB)." || true
            continue
        fi

        if [[ ${void_size_mib} -gt ${max_void_mib} ]]; then
            dialog_msgbox "Too Large" \
                "Maximum available space is ${max_void_mib} MiB.\n\
(Total ${total_mib} - Used ${used_mib} - 1 GiB safety margin)" || true
            continue
        fi

        break
    done

    local new_part_size=$(( total_mib - void_size_mib ))

    # Step 7: Confirmation
    dialog_yesno "Confirm Shrink" \
        "Shrink plan:\n\n\
  Partition:    ${selected_part} (${selected_fstype})\n\
  Current size: ${total_mib} MiB\n\
  New size:     ${new_part_size} MiB\n\
  Freed space:  ${void_size_mib} MiB (for Void)\n\n\
Proceed with shrink?" \
        || return "${TUI_BACK}"

    # Export results
    SHRINK_PARTITION="${selected_part}"
    SHRINK_PARTITION_FSTYPE="${selected_fstype}"
    SHRINK_NEW_SIZE_MIB="${new_part_size}"
    export SHRINK_PARTITION SHRINK_PARTITION_FSTYPE SHRINK_NEW_SIZE_MIB

    return "${TUI_NEXT}"
}

screen_disk_select() {
    # Build disk list for dialog
    local -a disk_items=()
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        disk_items+=("/dev/${name}" "${size} ${model} (${tran})")
    done

    if [[ ${#disk_items[@]} -eq 0 ]]; then
        dialog_msgbox "No Disks" "No suitable disks found. Cannot continue."
        return "${TUI_ABORT}"
    fi

    # Select target disk
    local selected_disk
    selected_disk=$(dialog_menu "Select Target Disk" "${disk_items[@]}") \
        || return "${TUI_BACK}"

    TARGET_DISK="${selected_disk}"
    export TARGET_DISK

    # Partition scheme — offer dual-boot if Windows, Linux OR macOS detected
    local scheme
    if [[ "${WINDOWS_DETECTED:-0}" == "1" || "${LINUX_DETECTED:-0}" == "1" || \
          "${MACOS_DETECTED:-0}" == "1" ]]; then
        local dualboot_desc="Dual-boot (reuse existing ESP)"
        [[ "${WINDOWS_DETECTED:-0}" == "1" ]] && dualboot_desc="Dual-boot with Windows (reuse existing ESP)"
        [[ "${LINUX_DETECTED:-0}" == "1" && "${WINDOWS_DETECTED:-0}" == "1" ]] && \
            dualboot_desc="Dual-boot with Windows + Linux (reuse existing ESP)"
        [[ "${LINUX_DETECTED:-0}" == "1" && "${WINDOWS_DETECTED:-0}" != "1" ]] && \
            dualboot_desc="Dual-boot with Linux (reuse existing ESP)"
        [[ "${MACOS_DETECTED:-0}" == "1" && "${WINDOWS_DETECTED:-0}" != "1" && \
           "${LINUX_DETECTED:-0}" != "1" ]] && \
            dualboot_desc="Dual-boot with macOS (reuse Apple ESP)"

        scheme=$(dialog_menu "Partition Scheme" \
            "dual-boot"  "${dualboot_desc}" \
            "auto"       "Auto-partition entire disk (DESTROYS ALL DATA)" \
            "manual"     "Manual partitioning (advanced)") \
            || return "${TUI_BACK}"
    else
        scheme=$(dialog_menu "Partition Scheme" \
            "auto"   "Auto-partition entire disk (DESTROYS ALL DATA)" \
            "manual" "Manual partitioning (advanced)") \
            || return "${TUI_BACK}"
    fi

    PARTITION_SCHEME="${scheme}"
    export PARTITION_SCHEME

    case "${scheme}" in
        dual-boot)
            # Reuse existing ESP
            if [[ -n "${WINDOWS_ESP:-}" ]]; then
                ESP_PARTITION="${WINDOWS_ESP}"
                ESP_REUSE="yes"
            elif [[ ${#ESP_PARTITIONS[@]} -gt 0 ]]; then
                # Let user pick ESP
                local -a esp_items=()
                local esp
                for esp in "${ESP_PARTITIONS[@]}"; do
                    esp_items+=("${esp}" "EFI System Partition")
                done
                ESP_PARTITION=$(dialog_menu "Select ESP" "${esp_items[@]}") \
                    || return "${TUI_BACK}"
                ESP_REUSE="yes"
            else
                dialog_msgbox "No ESP Found" \
                    "No existing ESP found. Falling back to auto-partition."
                PARTITION_SCHEME="auto"
                ESP_REUSE="no"
            fi
            export ESP_PARTITION ESP_REUSE

            # For dual-boot, select the partition for root
            local -a part_items=()
            _get_partition_info_for_dialog "${TARGET_DISK}" "${ESP_PARTITION}"

            if [[ ${#part_items[@]} -gt 0 ]]; then
                local use_existing
                use_existing=$(dialog_menu "Root Partition" \
                    "new"      "Create new partition in free space" \
                    "existing" "Use existing partition") \
                    || return "${TUI_BACK}"

                if [[ "${use_existing}" == "existing" ]]; then
                    ROOT_PARTITION=$(dialog_menu "Select Root Partition" "${part_items[@]}") \
                        || return "${TUI_BACK}"

                    # Warn if selected partition has a detected OS
                    if [[ -n "${DANGEROUS_PARTITIONS[${ROOT_PARTITION}]:-}" ]]; then
                        local os_name="${DANGEROUS_PARTITIONS[${ROOT_PARTITION}]}"

                        dialog_msgbox "WARNING: Existing OS Detected" \
                            "!!! DANGER !!!\n\n\
The partition you selected contains:\n\n\
  ${ROOT_PARTITION}: ${os_name}\n\n\
Formatting this partition will PERMANENTLY DESTROY\n\
this operating system and ALL its data.\n\n\
Type ERASE in the next dialog to confirm."

                        local erase_confirm
                        erase_confirm=$(dialog_inputbox "Confirm Destruction" \
                            "Type ERASE to confirm destruction of ${os_name} on ${ROOT_PARTITION}:" \
                            "") || return "${TUI_BACK}"

                        if [[ "${erase_confirm}" != "ERASE" ]]; then
                            dialog_msgbox "Cancelled" \
                                "Partition selection cancelled. You typed: '${erase_confirm}'"
                            return "${TUI_BACK}"
                        fi
                    fi

                    export ROOT_PARTITION
                else
                    # "Create new" — check free space, launch shrink wizard if needed
                    local free_mib
                    free_mib=$(disk_get_free_space_mib "${TARGET_DISK}")
                    if [[ ${free_mib} -lt ${VOID_MIN_SIZE_MIB} ]]; then
                        _shrink_wizard "${TARGET_DISK}" "${ESP_PARTITION}" \
                            || return "${TUI_BACK}"
                    fi
                fi
            fi
            ;;
        auto)
            ESP_REUSE="no"
            export ESP_REUSE

            # List operating systems living on THIS disk. A plain yes/no is
            # too weak a gate when a whole macOS/Windows install is about to
            # be erased, so those cases escalate to typing ERASE.
            local os_list="" os_part
            # Guard: DETECTED_OSES may be undeclared (config loaded from a
            # preset, resume path) and ${!arr[@]} is fatal under set -u.
            if declare -p DETECTED_OSES >/dev/null 2>&1; then
                for os_part in "${!DETECTED_OSES[@]}"; do
                    [[ "${os_part}" == "${TARGET_DISK}"* ]] || continue
                    os_list+="  ${os_part}: ${DETECTED_OSES[${os_part}]}\n"
                done
            fi

            if [[ -n "${os_list}" ]]; then
                dialog_msgbox "WARNING: Existing Operating Systems" \
                    "!!! DANGER !!!\n\n\
Auto-partitioning ${TARGET_DISK} will PERMANENTLY DESTROY:\n\n\
${os_list}\n\
Everything on this disk will be lost, including any\n\
recovery partition.\n\n\
Type ERASE in the next dialog to confirm."

                local auto_erase
                auto_erase=$(dialog_inputbox "Confirm Destruction" \
                    "Type ERASE to wipe ${TARGET_DISK} and every OS on it:" \
                    "") || return "${TUI_BACK}"

                if [[ "${auto_erase}" != "ERASE" ]]; then
                    dialog_msgbox "Cancelled" \
                        "Auto-partitioning cancelled. You typed: '${auto_erase}'"
                    return "${TUI_BACK}"
                fi
            else
                dialog_yesno "WARNING: Data Destruction" \
                    "Auto-partitioning will DESTROY ALL DATA on:\n\n  ${TARGET_DISK}\n\nAre you sure?" \
                    || return "${TUI_BACK}"
            fi
            ;;
        manual)
            dialog_msgbox "Manual Partitioning" \
                "You will be dropped to a shell for manual partitioning.\n\n\
Required partitions:\n\
  1. ESP (EFI System Partition) — at least 512 MiB, vfat\n\
  2. Root partition — your choice of filesystem\n\
  3. (Optional) Swap partition\n\n\
After partitioning, type 'exit' to return.\n\
You will then be asked to specify partition paths."

            PS1="(void-partition) \w \$ " bash --norc --noprofile || true

            ESP_PARTITION=$(dialog_inputbox "ESP Partition" \
                "Enter the path to the ESP partition:" \
                "/dev/${TARGET_DISK##*/}1") || return "${TUI_BACK}"
            ROOT_PARTITION=$(dialog_inputbox "Root Partition" \
                "Enter the path to the root partition:" \
                "/dev/${TARGET_DISK##*/}2") || return "${TUI_BACK}"

            local has_swap
            has_swap=$(dialog_yesno "Swap Partition" \
                "Did you create a swap partition?" && echo "yes" || echo "no")
            if [[ "${has_swap}" == "yes" ]]; then
                SWAP_PARTITION=$(dialog_inputbox "Swap Partition" \
                    "Enter the path to the swap partition:" \
                    "/dev/${TARGET_DISK##*/}3") || return "${TUI_BACK}"
                export SWAP_PARTITION
            fi

            local esp_reuse
            esp_reuse=$(dialog_yesno "ESP Reuse" \
                "Is this an existing ESP with other bootloaders? (e.g., Windows)" \
                && echo "yes" || echo "no")
            ESP_REUSE="${esp_reuse}"

            export ESP_PARTITION ROOT_PARTITION ESP_REUSE
            ;;
    esac

    einfo "Disk: ${TARGET_DISK}, Scheme: ${PARTITION_SCHEME}"
    return "${TUI_NEXT}"
}
