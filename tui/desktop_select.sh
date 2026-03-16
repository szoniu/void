#!/usr/bin/env bash
# tui/desktop_select.sh — Desktop environment selection: KDE Plasma vs GNOME
source "${LIB_DIR}/protection.sh"

screen_desktop_select() {
    local current="${DESKTOP_TYPE:-kde}"
    local on_kde="off" on_gnome="off"
    [[ "${current}" == "kde" ]] && on_kde="on"
    [[ "${current}" == "gnome" ]] && on_gnome="on"

    local choice
    choice=$(dialog_radiolist "Desktop Environment" \
        "kde"   "KDE Plasma — Modern desktop with SDDM"  "${on_kde}" \
        "gnome" "GNOME — Clean desktop with GDM"         "${on_gnome}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    DESKTOP_TYPE="${choice}"
    export DESKTOP_TYPE

    einfo "Desktop type: ${DESKTOP_TYPE}"
    return "${TUI_NEXT}"
}
