#!/usr/bin/env bash
# tui/swap_config.sh — Swap configuration: zram / partition / file / none
source "${LIB_DIR}/protection.sh"

screen_swap_config() {
    # Pre-select "partition" if user already specified a swap partition (manual mode)
    local current="${SWAP_TYPE:-zram}"
    [[ -n "${SWAP_PARTITION:-}" && -z "${SWAP_TYPE:-}" ]] && current="partition"
    local on_zram="off" on_partition="off" on_file="off" on_none="off"
    case "${current}" in
        zram)      on_zram="on" ;;
        partition)  on_partition="on" ;;
        file)       on_file="on" ;;
        none)       on_none="on" ;;
    esac

    local choice
    choice=$(dialog_radiolist "Swap Configuration" \
        "zram"      "zram — compressed RAM swap (recommended)" "${on_zram}" \
        "partition" "Swap partition — traditional disk swap" "${on_partition}" \
        "file"      "Swap file — file-based swap on root" "${on_file}" \
        "none"      "No swap — not recommended for low-RAM systems" "${on_none}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    SWAP_TYPE="${choice}"
    export SWAP_TYPE

    case "${SWAP_TYPE}" in
        zram)
            SWAP_SIZE_MIB=""  # zram auto-sizes
            ;;
        partition)
            if [[ -z "${SWAP_PARTITION:-}" ]]; then
                local size
                size=$(dialog_inputbox "Swap Partition Size" \
                    "Enter swap partition size in MiB:" \
                    "${SWAP_DEFAULT_SIZE_MIB}") || return "${TUI_BACK}"
                SWAP_SIZE_MIB="${size}"
            fi
            ;;
        file)
            local size
            size=$(dialog_inputbox "Swap File Size" \
                "Enter swap file size in MiB:" \
                "${SWAP_DEFAULT_SIZE_MIB}") || return "${TUI_BACK}"
            SWAP_SIZE_MIB="${size}"
            ;;
        none)
            SWAP_SIZE_MIB=""
            ;;
    esac

    export SWAP_SIZE_MIB

    einfo "Swap: ${SWAP_TYPE} (${SWAP_SIZE_MIB:-auto})"
    return "${TUI_NEXT}"
}
