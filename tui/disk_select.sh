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

    # Partition scheme — offer dual-boot if Windows OR Linux detected
    local scheme
    if [[ "${WINDOWS_DETECTED:-0}" == "1" || "${LINUX_DETECTED:-0}" == "1" ]]; then
        local dualboot_desc="Dual-boot (reuse existing ESP)"
        [[ "${WINDOWS_DETECTED:-0}" == "1" ]] && dualboot_desc="Dual-boot with Windows (reuse existing ESP)"
        [[ "${LINUX_DETECTED:-0}" == "1" && "${WINDOWS_DETECTED:-0}" == "1" ]] && \
            dualboot_desc="Dual-boot with Windows + Linux (reuse existing ESP)"
        [[ "${LINUX_DETECTED:-0}" == "1" && "${WINDOWS_DETECTED:-0}" != "1" ]] && \
            dualboot_desc="Dual-boot with Linux (reuse existing ESP)"

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
                fi
            fi
            ;;
        auto)
            ESP_REUSE="no"
            export ESP_REUSE

            dialog_yesno "WARNING: Data Destruction" \
                "Auto-partitioning will DESTROY ALL DATA on:\n\n  ${TARGET_DISK}\n\nAre you sure?" \
                || return "${TUI_BACK}"
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
