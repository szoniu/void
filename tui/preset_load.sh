#!/usr/bin/env bash
# tui/preset_load.sh — Optional preset loading screen
source "${LIB_DIR}/protection.sh"

screen_preset_load() {
    local choice
    choice=$(dialog_menu "Load Preset" \
        "skip"   "Start fresh configuration" \
        "file"   "Load preset from file" \
        "browse" "Browse example presets") || return "${TUI_BACK}"

    case "${choice}" in
        skip)
            return "${TUI_NEXT}"
            ;;
        file)
            local file
            file=$(dialog_inputbox "Preset File" \
                "Enter the path to your preset file:" \
                "/root/void-preset.conf") || return "${TUI_BACK}"

            if [[ ! -f "${file}" ]]; then
                dialog_msgbox "Error" "File not found: ${file}"
                return "${TUI_BACK}"
            fi

            preset_import "${file}"
            dialog_msgbox "Preset Loaded" \
                "Preset loaded from: ${file}\n\nHardware-specific values will be re-detected."
            return "${TUI_NEXT}"
            ;;
        browse)
            local -a presets=()
            local f
            for f in "${SCRIPT_DIR}/presets/"*.conf; do
                [[ -f "${f}" ]] || continue
                presets+=("${f}" "$(basename "${f}")")
            done

            if [[ ${#presets[@]} -eq 0 ]]; then
                dialog_msgbox "No Presets" "No example presets found in ${SCRIPT_DIR}/presets/"
                return "${TUI_BACK}"
            fi

            local selected
            selected=$(dialog_menu "Select Preset" "${presets[@]}") || return "${TUI_BACK}"

            preset_import "${selected}"
            dialog_msgbox "Preset Loaded" \
                "Preset loaded: $(basename "${selected}")\n\nHardware-specific values will be re-detected."
            return "${TUI_NEXT}"
            ;;
    esac
}
