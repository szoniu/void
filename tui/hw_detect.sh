#!/usr/bin/env bash
# tui/hw_detect.sh — Hardware detection summary screen
source "${LIB_DIR}/protection.sh"

screen_hw_detect() {
    dialog_infobox "Hardware Detection" \
        "Scanning your hardware...\n\nThis may take a moment."

    # Run detection
    detect_all_hardware

    # Show summary
    local summary
    summary=$(get_hardware_summary)

    dialog_yesno "Hardware Detected" \
        "${summary}\n\nDoes this look correct? Press Yes to continue, No to go back." \
        && return "${TUI_NEXT}" \
        || return "${TUI_BACK}"
}
