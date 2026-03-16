#!/usr/bin/env bash
# tui/summary.sh — Full summary + confirmation + countdown for Void Linux
source "${LIB_DIR}/protection.sh"

screen_summary() {
    # Validate configuration before showing summary
    local validation_errors
    validation_errors=$(validate_config) || {
        dialog_msgbox "Configuration Errors" \
            "Fix these issues before proceeding:\n\n${validation_errors}"
        return "${TUI_BACK}"
    }

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
    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        summary+="GPU:          ${IGPU_VENDOR:-?} + ${DGPU_DEVICE_NAME:-?} (PRIME)\n"
    else
        summary+="GPU:          ${GPU_VENDOR:-unknown} (${GPU_DRIVER:-auto})\n"
    fi
    summary+="Nonfree repo: ${ENABLE_NONFREE:-no}\n"
    [[ "${ENABLE_NOCTALIA:-no}" == "yes" ]] && summary+="Noctalia:     ${NOCTALIA_COMPOSITOR:-Hyprland} compositor\n"
    [[ "${ASUS_ROG_DETECTED:-0}" == "1" ]] && summary+="ASUS ROG:     detected\n"
    [[ "${ENABLE_ASUSCTL:-no}" == "yes" ]] && summary+="ROG tools:    asusctl enabled\n"
    [[ "${ENABLE_FINGERPRINT:-no}" == "yes" ]] && summary+="Fingerprint:  fprintd enabled\n"
    [[ "${ENABLE_THUNDERBOLT:-no}" == "yes" ]] && summary+="Thunderbolt:  bolt enabled\n"
    [[ "${ENABLE_SENSORS:-no}" == "yes" ]] && summary+="IIO sensors:  iio-sensor-proxy enabled\n"
    [[ "${ENABLE_WWAN:-no}" == "yes" ]] && summary+="WWAN LTE:     ModemManager enabled\n"
    summary+="\n"
    summary+="Username:     ${USERNAME:-user}\n"
    if [[ "${DESKTOP_TYPE:-kde}" == "gnome" ]]; then
        summary+="Desktop:      GNOME + GDM + PipeWire\n"
        [[ -n "${DESKTOP_EXTRAS:-}" ]] && summary+="GNOME apps:   ${DESKTOP_EXTRAS}\n"
    else
        summary+="Desktop:      KDE Plasma + SDDM + PipeWire\n"
        [[ -n "${DESKTOP_EXTRAS:-}" ]] && summary+="KDE apps:     ${DESKTOP_EXTRAS}\n"
    fi
    [[ -n "${EXTRA_PACKAGES:-}" ]] && summary+="Extra pkgs:   ${EXTRA_PACKAGES}\n"

    if [[ -n "${SHRINK_PARTITION:-}" ]]; then
        summary+="Shrink:       ${SHRINK_PARTITION} (${SHRINK_PARTITION_FSTYPE:-?}) -> ${SHRINK_NEW_SIZE_MIB:-?} MiB\n"
    fi

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
        if [[ -n "${ROOT_PARTITION:-}" ]]; then
            warning+="  ${ROOT_PARTITION} -> ${FILESYSTEM:-ext4}\n"
        else
            warning+="  (new partition will be created) -> ${FILESYSTEM:-ext4}\n"
        fi
        if [[ -n "${SHRINK_PARTITION:-}" ]]; then
            warning+="WILL BE SHRUNK (data preserved):\n"
            warning+="  ${SHRINK_PARTITION} (${SHRINK_PARTITION_FSTYPE:-?}) -> ${SHRINK_NEW_SIZE_MIB:-?} MiB\n"
        fi
        warning+="\n"

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
