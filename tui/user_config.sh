#!/usr/bin/env bash
# tui/user_config.sh — Root password, user creation, groups for Void Linux
source "${LIB_DIR}/protection.sh"

screen_user_config() {
    # Root password
    local root_pass1 root_pass2
    while true; do
        root_pass1=$(dialog_passwordbox "Root Password" \
            "Enter root password:") || return "${TUI_BACK}"

        if [[ -z "${root_pass1}" ]]; then
            dialog_msgbox "Error" "Password cannot be empty."
            continue
        fi

        root_pass2=$(dialog_passwordbox "Root Password" \
            "Confirm root password:") || return "${TUI_BACK}"

        if [[ "${root_pass1}" != "${root_pass2}" ]]; then
            dialog_msgbox "Error" "Passwords do not match. Try again."
            continue
        fi

        break
    done

    ROOT_PASSWORD_HASH=$(generate_password_hash "${root_pass1}")
    export ROOT_PASSWORD_HASH

    # Regular user
    local username
    username=$(dialog_inputbox "Username" \
        "Enter username for the regular user:" \
        "${USERNAME:-user}") || return "${TUI_BACK}"

    USERNAME="${username}"
    export USERNAME

    # User password
    local user_pass1 user_pass2
    while true; do
        user_pass1=$(dialog_passwordbox "User Password" \
            "Enter password for ${USERNAME}:") || return "${TUI_BACK}"

        if [[ -z "${user_pass1}" ]]; then
            dialog_msgbox "Error" "Password cannot be empty."
            continue
        fi

        user_pass2=$(dialog_passwordbox "User Password" \
            "Confirm password for ${USERNAME}:") || return "${TUI_BACK}"

        if [[ "${user_pass1}" != "${user_pass2}" ]]; then
            dialog_msgbox "Error" "Passwords do not match. Try again."
            continue
        fi

        break
    done

    USER_PASSWORD_HASH=$(generate_password_hash "${user_pass1}")
    export USER_PASSWORD_HASH

    # Groups (Void Linux defaults)
    USER_GROUPS="wheel,audio,video,input,storage,network"
    local groups
    groups=$(dialog_inputbox "User Groups" \
        "Additional groups for ${USERNAME}:" \
        "${USER_GROUPS}") || return "${TUI_BACK}"
    USER_GROUPS="${groups}"
    export USER_GROUPS

    einfo "User: ${USERNAME}, Groups: ${USER_GROUPS}"
    return "${TUI_NEXT}"
}
