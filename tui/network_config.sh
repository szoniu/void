#!/usr/bin/env bash
# tui/network_config.sh — Hostname and mirror selection
source "${LIB_DIR}/protection.sh"

screen_network_config() {
    # Hostname
    local hostname
    hostname=$(dialog_inputbox "Hostname" \
        "Enter the hostname for your system:" \
        "${HOSTNAME:-void}") || return "${TUI_BACK}"

    HOSTNAME="${hostname}"
    export HOSTNAME

    # Mirror selection
    local -a mirror_items
    readarray -t mirror_items < <(get_mirror_list_for_dialog)

    local mirror
    mirror=$(dialog_menu "Void Linux Mirror" "${mirror_items[@]}") || return "${TUI_BACK}"

    MIRROR_URL="${mirror}"
    export MIRROR_URL

    einfo "Hostname: ${HOSTNAME}, Mirror: ${MIRROR_URL}"
    return "${TUI_NEXT}"
}
