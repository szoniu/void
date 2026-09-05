#!/usr/bin/env bash
# tui/locale_config.sh — Timezone, locale, keymap configuration
source "${LIB_DIR}/protection.sh"

screen_locale_config() {
    # Timezone
    local tz
    tz=$(dialog_inputbox "Timezone" \
        "Enter your timezone (e.g., Europe/Warsaw, America/New_York):\n\n\
Tip: Run 'ls /usr/share/zoneinfo/' to see available zones." \
        "${TIMEZONE:-Europe/Warsaw}") || return "${TUI_BACK}"

    TIMEZONE="${tz}"
    export TIMEZONE

    # Apply timezone to live environment so logs show correct time
    export TZ="${TIMEZONE}"

    # Locale
    local locale_choice
    locale_choice=$(dialog_menu "System Locale" \
        "en_US.UTF-8" "English (US)" \
        "en_GB.UTF-8" "English (UK)" \
        "de_DE.UTF-8" "German" \
        "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" \
        "it_IT.UTF-8" "Italian" \
        "pl_PL.UTF-8" "Polish" \
        "pt_BR.UTF-8" "Portuguese (Brazil)" \
        "ru_RU.UTF-8" "Russian" \
        "ja_JP.UTF-8" "Japanese" \
        "zh_CN.UTF-8" "Chinese (Simplified)" \
        "ko_KR.UTF-8" "Korean" \
        "custom"       "Enter custom locale") \
        || return "${TUI_BACK}"

    if [[ "${locale_choice}" == "custom" ]]; then
        locale_choice=$(dialog_inputbox "Custom Locale" \
            "Enter locale (e.g., nl_NL.UTF-8):" \
            "en_US.UTF-8") || return "${TUI_BACK}"
    fi

    LOCALE="${locale_choice}"
    export LOCALE

    # Keymap
    local keymap_choice
    keymap_choice=$(dialog_menu "Console Keymap" \
        "us"    "US English" \
        "uk"    "UK English" \
        "de"    "German" \
        "fr"    "French" \
        "es"    "Spanish" \
        "it"    "Italian" \
        "pl"    "Polish" \
        "br"    "Brazilian Portuguese" \
        "ru"    "Russian" \
        "jp106" "Japanese" \
        "custom" "Enter custom keymap") \
        || return "${TUI_BACK}"

    if [[ "${keymap_choice}" == "custom" ]]; then
        keymap_choice=$(dialog_inputbox "Custom Keymap" \
            "Enter keymap name:" "us") || return "${TUI_BACK}"
    fi

    KEYMAP="${keymap_choice}"
    export KEYMAP

    # Console font. Lives here because it is the same file (/etc/rc.conf) and the
    # same kind of decision as the keymap. The list is hard-coded on purpose: the
    # names come from /usr/share/kbd/consolefonts in the TARGET system, which the
    # live medium cannot enumerate — system_set_console_font() validates the pick
    # in the chroot, where the answer actually exists.
    local suggested=""
    if declare -F suggest_console_font >/dev/null; then
        suggested="$(suggest_console_font 2>/dev/null)" || suggested=""
    fi

    # dialog_menu takes a title and then tag/description PAIRS — there is no
    # prompt parameter (checked in lib/dialog.sh), so the guidance goes into the
    # title and the descriptions, and the suggestion is marked on its own row.
    local font_title="Console Font"
    [[ -n "${suggested}" ]] && font_title+=" — panel suggests ${suggested}"

    local -a font_items=(
        "default"  "Keep the stock VGA font (no change)"
        "ter-v16n" "Terminus 16 — small"
        "ter-v20n" "Terminus 20 — 1080p"
        "ter-v24n" "Terminus 24 — large"
        "ter-v28n" "Terminus 28 — 1440p / Retina"
        "ter-v32n" "Terminus 32 — 4K"
    )
    # Mark the suggested row so the hint is visible where the choice is made,
    # not only in the title.
    local i
    for (( i = 0; i < ${#font_items[@]}; i += 2 )); do
        if [[ -n "${suggested}" && "${font_items[i]}" == "${suggested}" ]]; then
            font_items[i+1]+="  (suggested)"
        fi
    done

    local font_choice
    font_choice=$(dialog_menu "${font_title}" "${font_items[@]}") \
        || return "${TUI_BACK}"

    # "default" is a menu tag, not a font name — the empty value is what tells
    # system_set_console_font() to leave /etc/rc.conf alone.
    [[ "${font_choice}" == "default" ]] && font_choice=""

    CONSOLE_FONT="${font_choice}"
    export CONSOLE_FONT

    einfo "Timezone: ${TIMEZONE}, Locale: ${LOCALE}, Keymap: ${KEYMAP}, Console font: ${CONSOLE_FONT:-default}"
    return "${TUI_NEXT}"
}
