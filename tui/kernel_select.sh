#!/usr/bin/env bash
# tui/kernel_select.sh — Kernel type: mainline vs LTS (+ Surface options)
source "${LIB_DIR}/protection.sh"

screen_kernel_select() {
    local current="${KERNEL_TYPE:-mainline}"

    if [[ "${SURFACE_DETECTED:-0}" == "1" ]]; then
        # Surface hardware: show 3 kernel options
        local on_mainline="off" on_lts="off" on_surface="off"
        [[ "${current}" == "mainline" ]] && on_mainline="on"
        [[ "${current}" == "lts" ]] && on_lts="on"
        [[ "${current}" == "surface-patched" ]] && on_surface="on"
        # Default to mainline if nothing selected
        if [[ "${on_mainline}" == "off" && "${on_lts}" == "off" && "${on_surface}" == "off" ]]; then
            on_mainline="on"
        fi

        local choice
        choice=$(dialog_radiolist "Kernel Selection (Surface)" \
            "mainline"        "Latest stable kernel — good Surface support upstream"            "${on_mainline}" \
            "lts"             "Long-term support kernel — stable, may lack Surface patches"     "${on_lts}" \
            "surface-patched" "Surface kernel — compiled from source with patches (30-60 min)"  "${on_surface}") \
            || return "${TUI_BACK}"
    else
        # Standard hardware: 2 options
        local on_mainline="off" on_lts="off"
        [[ "${current}" == "mainline" ]] && on_mainline="on"
        [[ "${current}" == "lts" ]] && on_lts="on"

        local choice
        choice=$(dialog_radiolist "Kernel Selection" \
            "mainline" "Latest stable kernel (linux package)" "${on_mainline}" \
            "lts"      "Long-term support kernel (linux-lts package)" "${on_lts}") \
            || return "${TUI_BACK}"
    fi

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    KERNEL_TYPE="${choice}"
    export KERNEL_TYPE

    einfo "Kernel type: ${KERNEL_TYPE}"
    return "${TUI_NEXT}"
}
