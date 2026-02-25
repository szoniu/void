#!/usr/bin/env bash
# tui/summary.sh — Full summary + confirmation + countdown for Void Linux
source "${LIB_DIR}/protection.sh"

screen_summary() {
    local summary=""
    summary+="=== Installation Summary ===\n\n"
    summary+="Init system:  runit\n"
    summary+="Target disk:  ${TARGET_DISK:-?}\n"
    summary+="Partitioning: ${PARTITION_SCHEME:-auto}\n"
    summary+="Filesystem:   ${FILESYSTEM:-ext4}\n"
    [[ "${FILESYSTEM}" == "btrfs" ]] && summary+="Subvolumes:   ${BTRFS_SUBVOLUMES:-default}\n"
    summary+="Swap:         ${SWAP_TYPE:-zram}"
    [[ -n "${SWAP_SIZE_MIB:-}" ]] && summary+=" (${SWAP_SIZE_MIB} MiB)"
    summary+="\n"
    summary+="\n"
    summary+="Hostname:     ${HOSTNAME:-void}\n"
    summary+="Mirror:       ${MIRROR_URL:-auto}\n"
    summary+="Timezone:     ${TIMEZONE:-UTC}\n"
    summary+="Locale:       ${LOCALE:-en_US.UTF-8}\n"
    summary+="Keymap:       ${KEYMAP:-us}\n"
    summary+="\n"
    summary+="Kernel:       ${KERNEL_TYPE:-mainline}\n"
    summary+="GPU:          ${GPU_VENDOR:-unknown} (${GPU_DRIVER:-auto})\n"
    summary+="Nonfree repo: ${ENABLE_NONFREE:-no}\n"
    summary+="\n"
    summary+="Username:     ${USERNAME:-user}\n"
    summary+="Desktop:      KDE Plasma + SDDM + PipeWire\n"
    [[ -n "${DESKTOP_EXTRAS:-}" ]] && summary+="KDE apps:     ${DESKTOP_EXTRAS}\n"
    [[ -n "${EXTRA_PACKAGES:-}" ]] && summary+="Extra pkgs:   ${EXTRA_PACKAGES}\n"

    if [[ "${ESP_REUSE:-no}" == "yes" ]]; then
        summary+="\nDual-boot:    YES (reusing ESP ${ESP_PARTITION:-?})\n"
    fi

    # Show detected operating systems
    if [[ ${#DETECTED_OSES[@]} -gt 0 ]]; then
        summary+="\nDetected OSes:\n"
        local p
        for p in "${!DETECTED_OSES[@]}"; do
            summary+="  ${p}: ${DETECTED_OSES[${p}]}\n"
        done
    fi

    # Show summary
    dialog_msgbox "Installation Summary" "${summary}" || return "${TUI_BACK}"

    # Destructive warning
    if [[ "${PARTITION_SCHEME:-auto}" == "auto" ]]; then
        local warning=""
        warning+="!!! WARNING: DATA DESTRUCTION !!!\n\n"
        warning+="The following disk will be COMPLETELY ERASED:\n\n"
        warning+="  ${TARGET_DISK:-?}\n\n"
        warning+="ALL existing data on this disk will be permanently lost.\n"
        warning+="This action CANNOT be undone.\n\n"
        warning+="Type 'YES' in the next dialog to confirm."

        dialog_msgbox "WARNING" "${warning}" || return "${TUI_BACK}"

        local confirmation
        confirmation=$(dialog_inputbox "Confirm Installation" \
            "Type YES (all caps) to confirm and begin installation:" \
            "") || return "${TUI_BACK}"

        if [[ "${confirmation}" != "YES" ]]; then
            dialog_msgbox "Cancelled" "Installation cancelled. You typed: '${confirmation}'"
            return "${TUI_BACK}"
        fi
    elif [[ "${PARTITION_SCHEME:-auto}" == "dual-boot" ]]; then
        local warning=""
        warning+="!!! DUAL-BOOT INSTALLATION !!!\n\n"

        # What WILL be formatted
        warning+="WILL BE FORMATTED (data destroyed):\n"
        warning+="  ${ROOT_PARTITION:-?} -> ${FILESYSTEM:-ext4}\n\n"

        # What will SURVIVE
        warning+="WILL BE PRESERVED:\n"
        warning+="  ${ESP_PARTITION:-?}: EFI System Partition\n"
        local p
        for p in "${!DETECTED_OSES[@]}"; do
            [[ "${p}" == "${ROOT_PARTITION:-}" ]] && continue
            warning+="  ${p}: ${DETECTED_OSES[${p}]}\n"
        done

        warning+="\nType 'YES' in the next dialog to confirm."

        dialog_msgbox "WARNING" "${warning}" || return "${TUI_BACK}"

        local confirmation
        confirmation=$(dialog_inputbox "Confirm Dual-Boot Installation" \
            "Type YES (all caps) to confirm and begin installation:" \
            "") || return "${TUI_BACK}"

        if [[ "${confirmation}" != "YES" ]]; then
            dialog_msgbox "Cancelled" "Installation cancelled. You typed: '${confirmation}'"
            return "${TUI_BACK}"
        fi
    else
        dialog_yesno "Confirm Installation" \
            "Ready to begin installation. Continue?" \
            || return "${TUI_BACK}"
    fi

    # Countdown
    einfo "Installation starting in ${COUNTDOWN_DEFAULT} seconds..."
    (
        local i
        for (( i = COUNTDOWN_DEFAULT; i > 0; i-- )); do
            echo "$(( (COUNTDOWN_DEFAULT - i) * 100 / COUNTDOWN_DEFAULT ))"
            sleep 1
        done
        echo "100"
    ) | dialog_gauge "Starting Installation" \
        "Installation will begin in ${COUNTDOWN_DEFAULT} seconds...\nPress Ctrl+C to abort."

    return "${TUI_NEXT}"
}
