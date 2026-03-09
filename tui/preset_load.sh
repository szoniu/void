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
            local default_preset=""
            local latest
            latest=$(ls -t "${SCRIPT_DIR}/presets/"custom-*.conf /root/void-preset*.conf 2>/dev/null | head -1) || true
            [[ -n "${latest}" ]] && default_preset="${latest}"
            : "${default_preset:=${SCRIPT_DIR}/presets/custom.conf}"

            local file
            file=$(dialog_inputbox "Preset File" \
                "Enter the path to your preset file:" \
                "${default_preset}") || return "${TUI_BACK}"

            if [[ ! -f "${file}" ]]; then
                dialog_msgbox "Error" "File not found: ${file}"
                return "${TUI_BACK}"
            fi

            preset_import "${file}"

            local skip_rc=0
            dialog_yesno "Preset Loaded" \
                "Preset loaded from: ${file}\n\nSkip to password setup + summary?\n\nChoose 'No' to review all settings." \
                || skip_rc=$?
            if [[ ${skip_rc} -eq 0 ]]; then
                # Skip configuration screens, jump to user_config (passwords)
                # hw_detect (index 2) will run next, then we jump past config screens
                _PRESET_SKIP_TO_USER=1
                export _PRESET_SKIP_TO_USER
            fi
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

            local skip_rc=0
            dialog_yesno "Preset Loaded" \
                "Preset loaded: $(basename "${selected}")\n\nSkip to password setup + summary?\n\nChoose 'No' to review all settings." \
                || skip_rc=$?
            if [[ ${skip_rc} -eq 0 ]]; then
                _PRESET_SKIP_TO_USER=1
                export _PRESET_SKIP_TO_USER
            fi
            return "${TUI_NEXT}"
            ;;
    esac
}
