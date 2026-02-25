#!/usr/bin/env bash
# mirrors.sh — Void Linux mirror list
source "${LIB_DIR}/protection.sh"

# Void Linux mirrors
# Format: URL
readonly -a VOID_MIRRORS=(
    "https://repo-default.voidlinux.org"
    "https://repo-fi.voidlinux.org"
    "https://repo-de.voidlinux.org"
    "https://repo-us.voidlinux.org"
    "https://mirrors.servercentral.com/voidlinux"
    "https://void.sakamoto.pl"
    "https://mirror.clarkson.edu/voidlinux"
    "https://mirror.puzzle.ch/voidlinux"
    "https://ftp.swin.edu.au/voidlinux"
    "https://void.webconverger.org"
    "https://mirror.aarnet.edu.au/pub/voidlinux"
    "https://ftp.lysator.liu.se/pub/voidlinux"
)

# get_mirror_list_for_dialog — Return mirror list formatted for dialog menu
get_mirror_list_for_dialog() {
    local url
    for url in "${VOID_MIRRORS[@]}"; do
        local label
        case "${url}" in
            *repo-default*) label="Default (auto)" ;;
            *repo-fi*)      label="Finland" ;;
            *repo-de*)      label="Germany" ;;
            *repo-us*)      label="USA (official)" ;;
            *servercentral*) label="USA (ServerCentral)" ;;
            *sakamoto*)     label="Poland" ;;
            *clarkson*)     label="USA (Clarkson)" ;;
            *puzzle*)       label="Switzerland" ;;
            *swin*)         label="Australia (Swinburne)" ;;
            *webconverger*) label="Singapore" ;;
            *aarnet*)       label="Australia (AARNet)" ;;
            *lysator*)      label="Sweden" ;;
            *)              label="${url}" ;;
        esac
        echo "${url}" "${label}"
    done
}
