#!/usr/bin/env bash
# tui/preset_save.sh — Optional preset export for Void Linux
source "${LIB_DIR}/protection.sh"

screen_preset_save() {
    dialog_yesno "Save Preset" \
        "Would you like to export your configuration as a preset?\n\n\
This allows you to reuse this configuration on other machines." \
        || return "${TUI_NEXT}"  # Skip is "next", not "back"

    local file
    file=$(dialog_inputbox "Preset File" \
        "Enter the path to save the preset:" \
        "/root/void-preset-$(date +%Y%m%d).conf") || return "${TUI_BACK}"

    preset_export "${file}"

    dialog_msgbox "Preset Saved" \
        "Configuration preset saved to:\n  ${file}\n\n\
You can load this preset on another machine using:\n\
  ./install.sh --configure  (then select 'Load preset')"

    return "${TUI_NEXT}"
}
