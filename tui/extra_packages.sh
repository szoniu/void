#!/usr/bin/env bash
# tui/extra_packages.sh — Additional packages + nonfree repo + peripheral tools
source "${LIB_DIR}/protection.sh"

screen_extra_packages() {
    # Step 1: Build checklist — base items + conditional hardware items
    local -a checklist_args=(
        "fastfetch"    "System info tool (like neofetch)"        "on"
        "btop"         "Resource monitor (top/htop alternative)" "on"
        "kitty"        "GPU-accelerated terminal emulator"       "on"
        "fish-shell"   "Fish shell"                              "off"
        "zsh"          "Z shell"                                 "off"
        "neovim"       "Neovim text editor"                      "off"
        "tmux"         "Terminal multiplexer"                    "off"
        "htop"         "Interactive process viewer"              "off"
        "ranger"       "Console file manager"                    "off"
        "flatpak"      "Flatpak application manager"             "off"
        "v4l-utils"    "Video4Linux webcam/capture utilities"    "off"
    )

    # Conditional: ASUS ROG tools (only shown when ROG hardware detected)
    if [[ "${ASUS_ROG_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("asusctl" "ASUS ROG control (fan curves, RGB, performance)" "on")
    fi

    # Conditional: Fingerprint reader (only shown when fingerprint hardware detected)
    if [[ "${FINGERPRINT_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("fingerprint" "Fingerprint auth (fprintd + libfprint)" "on")
    fi

    # Conditional: Thunderbolt (only shown when Thunderbolt controller detected)
    if [[ "${THUNDERBOLT_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("thunderbolt" "Thunderbolt device manager (bolt)" "on")
    fi

    # Conditional: IIO sensors (only shown when sensors detected)
    if [[ "${SENSORS_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("iio-sensors" "Auto-rotation / ambient light sensor proxy" "on")
    fi

    # Conditional: WWAN LTE modem (only shown when WWAN hardware detected)
    if [[ "${WWAN_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("wwan-tools" "WWAN LTE modem support (ModemManager)" "on")
    fi

    checklist_args+=(
        "nonfree-repo" "Enable nonfree repository"               "off"
    )

    local selections
    selections=$(dialog_checklist "Extra Packages" "${checklist_args[@]}") || return "${TUI_BACK}"

    # Parse checklist selections
    local cleaned
    cleaned=$(echo "${selections}" | tr -d '"')

    local -a pkgs=()
    ENABLE_NONFREE="${ENABLE_NONFREE:-no}"
    ENABLE_ASUSCTL="${ENABLE_ASUSCTL:-no}"
    ENABLE_FINGERPRINT="${ENABLE_FINGERPRINT:-no}"
    ENABLE_THUNDERBOLT="${ENABLE_THUNDERBOLT:-no}"
    ENABLE_SENSORS="${ENABLE_SENSORS:-no}"
    ENABLE_WWAN="${ENABLE_WWAN:-no}"

    local item
    for item in ${cleaned}; do
        case "${item}" in
            nonfree-repo)
                ENABLE_NONFREE="yes"
                ;;
            asusctl)
                ENABLE_ASUSCTL="yes"
                ;;
            fingerprint)
                ENABLE_FINGERPRINT="yes"
                ;;
            thunderbolt)
                ENABLE_THUNDERBOLT="yes"
                ;;
            iio-sensors)
                ENABLE_SENSORS="yes"
                ;;
            wwan-tools)
                ENABLE_WWAN="yes"
                ;;
            *)
                pkgs+=("${item}")
                ;;
        esac
    done

    export ENABLE_NONFREE ENABLE_ASUSCTL ENABLE_FINGERPRINT \
           ENABLE_THUNDERBOLT ENABLE_SENSORS ENABLE_WWAN

    # Step 2: Free-form input for additional packages
    local extra
    extra=$(dialog_inputbox "Additional Packages" \
        "Enter any additional packages (space-separated).\n\n\
Examples: nano lsof curl git\n\n\
Leave empty to skip:" \
        "") || return "${TUI_BACK}"

    # Combine checklist + free-form packages
    local all_pkgs="${pkgs[*]}"
    [[ -n "${extra}" ]] && all_pkgs="${all_pkgs:+${all_pkgs} }${extra}"

    EXTRA_PACKAGES="${all_pkgs}"
    export EXTRA_PACKAGES

    einfo "Extra packages: ${EXTRA_PACKAGES:-none}"
    [[ "${ENABLE_NONFREE}" == "yes" ]] && einfo "Nonfree repository: enabled"
    [[ "${ENABLE_ASUSCTL}" == "yes" ]] && einfo "ASUS ROG tools: enabled"
    [[ "${ENABLE_FINGERPRINT}" == "yes" ]] && einfo "Fingerprint reader: fprintd enabled"
    [[ "${ENABLE_THUNDERBOLT}" == "yes" ]] && einfo "Thunderbolt: bolt enabled"
    [[ "${ENABLE_SENSORS}" == "yes" ]] && einfo "IIO sensors: iio-sensor-proxy enabled"
    [[ "${ENABLE_WWAN}" == "yes" ]] && einfo "WWAN LTE: ModemManager enabled"
    return "${TUI_NEXT}"
}
