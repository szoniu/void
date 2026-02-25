#!/usr/bin/env bash
# tui/kernel_select.sh — Kernel type: mainline vs LTS
source "${LIB_DIR}/protection.sh"

screen_kernel_select() {
    local current="${KERNEL_TYPE:-mainline}"
    local on_mainline="off" on_lts="off"
    [[ "${current}" == "mainline" ]] && on_mainline="on"
    [[ "${current}" == "lts" ]] && on_lts="on"

    local choice
    choice=$(dialog_radiolist "Kernel Selection" \
        "mainline" "Latest stable kernel (linux package)" "${on_mainline}" \
        "lts"      "Long-term support kernel (linux-lts package)" "${on_lts}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    KERNEL_TYPE="${choice}"
    export KERNEL_TYPE

    einfo "Kernel type: ${KERNEL_TYPE}"
    return "${TUI_NEXT}"
}
