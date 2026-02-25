#!/usr/bin/env bash
# tui/desktop_config.sh — KDE Plasma + desktop options for Void Linux
source "${LIB_DIR}/protection.sh"

screen_desktop_config() {
    local info_text=""
    info_text+="The following desktop environment will be installed:\n\n"
    info_text+="  KDE Plasma Desktop (kde5 + kde5-baseapps)\n"
    info_text+="  Display Manager: SDDM\n"
    info_text+="  Audio: PipeWire (with PulseAudio compatibility)\n"
    info_text+="  Session: elogind (required for KDE without systemd)\n"
    info_text+="  Networking: NetworkManager\n\n"
    info_text+="Additional applications can be selected below."

    dialog_msgbox "Desktop Environment" "${info_text}" || return "${TUI_ABORT}"

    # Desktop application checklist
    local extras
    extras=$(dialog_checklist "Desktop Applications" \
        "konsole"      "Terminal emulator"        "on"  \
        "dolphin"      "File manager"             "on"  \
        "kate"         "Text editor"              "on"  \
        "firefox"      "Firefox web browser"      "on"  \
        "gwenview"     "Image viewer"             "on"  \
        "okular"       "Document viewer"          "on"  \
        "ark"          "Archive manager"          "on"  \
        "spectacle"    "Screenshot tool"          "on"  \
        "kcalc"        "Calculator"               "off" \
        "kwalletmanager" "Wallet manager"         "off" \
        "elisa"        "Music player"             "off" \
        "vlc"          "VLC media player"         "off" \
        "gimp"         "Image editor"             "off" \
        "inkscape"     "Vector graphics editor"   "off" \
        "krita"        "Digital painting"         "off" \
        "kdenlive"     "Video editor"             "off" \
        "obs"          "Screen recorder/streamer" "off" \
        "libreoffice"  "LibreOffice suite"        "off" \
        "thunderbird"  "Thunderbird email client" "off") \
        || return "${TUI_BACK}"

    DESKTOP_EXTRAS="${extras}"
    export DESKTOP_EXTRAS

    einfo "Desktop extras: ${DESKTOP_EXTRAS}"
    return "${TUI_NEXT}"
}
