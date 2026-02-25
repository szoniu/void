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

    einfo "Timezone: ${TIMEZONE}, Locale: ${LOCALE}, Keymap: ${KEYMAP}"
    return "${TUI_NEXT}"
}
