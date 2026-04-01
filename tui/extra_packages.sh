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

    # Conditional: Surface touchscreen daemon (only shown when Surface hardware detected)
    if [[ "${SURFACE_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("surface-tools" "Surface touchscreen daemon (iptsd)" "on")
    fi

    # Hyprland ecosystem — standalone Wayland desktop
    checklist_args+=("hyprland-ecosystem" "Hyprland + ekosystem (waybar, wofi, mako, grim...)" "$( [[ "${ENABLE_HYPRLAND:-no}" == "yes" ]] && echo "on" || echo "off" )")

    # Noctalia Shell — Wayland shell with compositor
    checklist_args+=("noctalia-shell" "Noctalia Shell (Wayland shell + compositor)" "$( [[ "${ENABLE_NOCTALIA:-no}" == "yes" ]] && echo "on" || echo "off" )")

    # Gaming — Steam, gamescope, MangoHud
    checklist_args+=("gaming" "Gaming (Steam, gamescope, MangoHud)" "$( [[ "${ENABLE_GAMING:-no}" == "yes" ]] && echo "on" || echo "off" )")

    checklist_args+=(
        "nonfree-repo" "Enable nonfree repository"               "$( [[ "${ENABLE_NONFREE:-no}" == "yes" ]] && echo "on" || echo "off" )"
    )

    local selections
    selections=$(dialog_checklist "Extra Packages" "${checklist_args[@]}") || return "${TUI_BACK}"

    # Parse checklist selections
    local cleaned
    cleaned=$(echo "${selections}" | tr -d '"')

    local -a pkgs=()
    ENABLE_NONFREE="no"
    ENABLE_HYPRLAND="no"
    ENABLE_NOCTALIA="no"
    ENABLE_GAMING="no"
    ENABLE_ASUSCTL="no"
    ENABLE_FINGERPRINT="no"
    ENABLE_THUNDERBOLT="no"
    ENABLE_SENSORS="no"
    ENABLE_WWAN="no"
    ENABLE_IPTSD="no"

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
            surface-tools)
                ENABLE_IPTSD="yes"
                ;;
            hyprland-ecosystem)
                ENABLE_HYPRLAND="yes"
                ;;
            gaming)
                ENABLE_GAMING="yes"
                # Gaming requires nonfree repo (Steam)
                ENABLE_NONFREE="yes"
                ;;
            noctalia-shell)
                ENABLE_NOCTALIA="yes"
                # Ask which Wayland compositor to install
                local compositor
                compositor=$(dialog_radiolist "Select Wayland Compositor for Noctalia" \
                    "Hyprland" "Hyprland — dynamic tiling Wayland compositor" "on"  \
                    "niri"     "Niri — scrollable-tiling Wayland compositor"  "off" \
                    "sway"     "Sway — i3-compatible Wayland compositor"      "off" \
                ) || return "${TUI_BACK}"
                NOCTALIA_COMPOSITOR=$(echo "${compositor}" | tr -d '"')
                export NOCTALIA_COMPOSITOR
                ;;
            *)
                pkgs+=("${item}")
                ;;
        esac
    done

    export ENABLE_NONFREE ENABLE_HYPRLAND ENABLE_NOCTALIA ENABLE_GAMING \
           ENABLE_ASUSCTL ENABLE_FINGERPRINT ENABLE_THUNDERBOLT ENABLE_SENSORS ENABLE_WWAN \
           ENABLE_IPTSD

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
    [[ "${ENABLE_HYPRLAND}" == "yes" ]] && einfo "Hyprland ecosystem: enabled"
    [[ "${ENABLE_NOCTALIA}" == "yes" ]] && einfo "Noctalia Shell: enabled (compositor: ${NOCTALIA_COMPOSITOR:-Hyprland})"
    [[ "${ENABLE_GAMING}" == "yes" ]] && einfo "Gaming: enabled (Steam, gamescope, MangoHud)"
    [[ "${ENABLE_ASUSCTL}" == "yes" ]] && einfo "ASUS ROG tools: enabled"
    [[ "${ENABLE_FINGERPRINT}" == "yes" ]] && einfo "Fingerprint reader: fprintd enabled"
    [[ "${ENABLE_THUNDERBOLT}" == "yes" ]] && einfo "Thunderbolt: bolt enabled"
    [[ "${ENABLE_SENSORS}" == "yes" ]] && einfo "IIO sensors: iio-sensor-proxy enabled"
    [[ "${ENABLE_WWAN}" == "yes" ]] && einfo "WWAN LTE: ModemManager enabled"
    [[ "${ENABLE_IPTSD}" == "yes" ]] && einfo "Surface tools: iptsd enabled"
    return "${TUI_NEXT}"
}
