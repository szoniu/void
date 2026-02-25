#!/usr/bin/env bash
# dialog.sh — Dialog/whiptail wrapper, navigation stack, wizard runner
source "${LIB_DIR}/protection.sh"

# Detect dialog backend
_detect_dialog_backend() {
    if command -v dialog &>/dev/null; then
        DIALOG_CMD="dialog"
    elif command -v whiptail &>/dev/null; then
        DIALOG_CMD="whiptail"
    else
        die "Neither dialog nor whiptail found. Install one of them."
    fi
    export DIALOG_CMD
}

# Dialog dimensions
readonly DIALOG_HEIGHT=22
readonly DIALOG_WIDTH=76
readonly DIALOG_LIST_HEIGHT=14

# Initialize dialog backend
init_dialog() {
    _detect_dialog_backend
    einfo "Using dialog backend: ${DIALOG_CMD}"

    # Set dialog theme for a polished look
    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        local rc_file="${DATA_DIR}/dialogrc"
        if [[ -f "${rc_file}" ]]; then
            export DIALOGRC="${rc_file}"
        fi
    fi
}

# --- Primitives ---

# dialog_infobox — Display a message without waiting for input (returns immediately)
dialog_infobox() {
    local title="$1" text="$2"
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --infobox "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_msgbox — Display a message box
dialog_msgbox() {
    local title="$1" text="$2"
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --msgbox "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_yesno — Ask yes/no question. Returns 0=yes, 1=no
dialog_yesno() {
    local title="$1" text="$2"
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --yesno "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_inputbox — Get text input. Prints result to stdout.
dialog_inputbox() {
    local title="$1" text="$2" default="${3:-}"
    local result
    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --inputbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${default}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --inputbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${default}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_passwordbox — Get password input
dialog_passwordbox() {
    local title="$1" text="$2"
    local result
    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --insecure --passwordbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --passwordbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_menu — Display a menu. Prints selected tag to stdout.
# Usage: dialog_menu "title" "tag1" "desc1" "tag2" "desc2" ...
dialog_menu() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --menu "Choose an option:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --menu "Choose an option:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_radiolist — Display a radio list. Prints selected tag to stdout.
# Usage: dialog_radiolist "title" "tag1" "desc1" "on/off" "tag2" "desc2" "on/off" ...
dialog_radiolist() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --radiolist "Select one:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --radiolist "Select one:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_checklist — Display a checklist. Prints selected tags to stdout.
# Usage: dialog_checklist "title" "tag1" "desc1" "on/off" ...
dialog_checklist() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --checklist "Select items:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --checklist "Select items:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_gauge — Display a progress gauge
# Usage: dialog_gauge "title" "text" <percentage>
# Reads percentage updates from stdin (echo "50" | dialog_gauge ...)
dialog_gauge() {
    local title="$1" text="$2" percent="${3:-0}"
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --gauge "${text}" \
        8 "${DIALOG_WIDTH}" "${percent}"
}

# dialog_textbox — Display a text file in a scrollable box
dialog_textbox() {
    local title="$1" file="$2"
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --textbox "${file}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_prgbox — Run a command and show output in a box
dialog_prgbox() {
    local title="$1"
    shift
    local cmd
    cmd=$(printf '%q ' "$@")
    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --prgbox "${cmd}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
    else
        # whiptail doesn't have prgbox, fall back to msgbox
        local output
        output=$("$@" 2>&1) || true
        dialog_msgbox "${title}" "${output}"
    fi
}

# --- Wizard navigation ---

# Navigation stack for wizard
declare -a _WIZARD_SCREENS=()
_WIZARD_INDEX=0

# register_wizard_screens — Set the ordered list of screen functions
register_wizard_screens() {
    _WIZARD_SCREENS=("$@")
    _WIZARD_INDEX=0
}

# run_wizard — Execute the wizard, handling back/next/abort navigation
run_wizard() {
    local total=${#_WIZARD_SCREENS[@]}

    if [[ ${total} -eq 0 ]]; then
        die "No wizard screens registered"
    fi

    while (( _WIZARD_INDEX < total )); do
        local screen_func="${_WIZARD_SCREENS[${_WIZARD_INDEX}]}"

        elog "Running wizard screen ${_WIZARD_INDEX}/${total}: ${screen_func}"

        # Clear terminal to prevent flicker between screens
        clear 2>/dev/null

        local rc=0
        "${screen_func}" || rc=$?

        case ${rc} in
            "${TUI_NEXT}"|0)
                (( _WIZARD_INDEX++ )) || true
                ;;
            "${TUI_BACK}"|1)
                if (( _WIZARD_INDEX > 0 )); then
                    (( _WIZARD_INDEX-- )) || true
                else
                    ewarn "Already at first screen"
                fi
                ;;
            "${TUI_ABORT}"|2)
                if dialog_yesno "Abort Installation" \
                    "Are you sure you want to abort the installation?"; then
                    die "Installation aborted by user"
                fi
                ;;
            *)
                eerror "Unknown return code ${rc} from ${screen_func}"
                ;;
        esac
    done

    einfo "Wizard completed"
}

# dialog_nav_menu — Menu with Back/Abort options built-in
# Returns selection via stdout, handles Cancel=back
dialog_nav_menu() {
    local title="$1"
    shift

    local result
    result=$(dialog_menu "${title}" "$@") || {
        # Cancel pressed — treat as back
        return "${TUI_BACK}"
    }
    echo "${result}"
    return "${TUI_NEXT}"
}
