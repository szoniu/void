#!/usr/bin/env bash
# tui/extra_packages.sh — Additional packages + nonfree repo for Void Linux
source "${LIB_DIR}/protection.sh"

screen_extra_packages() {
    # Step 1: Checklist with popular packages and nonfree option
    local selections
    selections=$(dialog_checklist "Extra Packages" \
        "fastfetch"    "System info tool (like neofetch)"        "on"  \
        "btop"         "Resource monitor (top/htop alternative)" "on"  \
        "kitty"        "GPU-accelerated terminal emulator"       "on"  \
        "fish-shell"   "Fish shell"                              "off" \
        "zsh"          "Z shell"                                 "off" \
        "neovim"       "Neovim text editor"                      "off" \
        "tmux"         "Terminal multiplexer"                    "off" \
        "htop"         "Interactive process viewer"              "off" \
        "ranger"       "Console file manager"                    "off" \
        "flatpak"      "Flatpak application manager"             "off" \
        "nonfree-repo" "Enable nonfree repository"               "off" \
    ) || return "${TUI_BACK}"

    # Parse checklist selections
    local cleaned
    cleaned=$(echo "${selections}" | tr -d '"')

    local -a pkgs=()
    ENABLE_NONFREE="${ENABLE_NONFREE:-no}"

    local item
    for item in ${cleaned}; do
        case "${item}" in
            nonfree-repo)
                ENABLE_NONFREE="yes"
                ;;
            *)
                pkgs+=("${item}")
                ;;
        esac
    done

    export ENABLE_NONFREE

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
    return "${TUI_NEXT}"
}
