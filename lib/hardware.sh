#!/usr/bin/env bash
# hardware.sh — Hardware detection: CPU, GPU, disks, ESP, installed OSes
source "${LIB_DIR}/protection.sh"

# --- CPU Detection ---

# detect_cpu — Detect CPU vendor, model name, core count
# No CPU_MARCH detection (Void uses binary packages, not source-compiled)
detect_cpu() {
    CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}') || CPU_VENDOR="unknown"
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}') || CPU_MODEL="unknown"
    CPU_CORES=$(nproc 2>/dev/null) || CPU_CORES=4

    export CPU_VENDOR CPU_MODEL CPU_CORES

    einfo "CPU: ${CPU_MODEL}"
    einfo "CPU cores: ${CPU_CORES}"
}

# --- GPU Detection ---

# detect_gpu — Detect GPU vendor, device ID, and driver recommendation
detect_gpu() {
    GPU_VENDOR=""
    GPU_DEVICE_ID=""
    GPU_DEVICE_NAME=""
    GPU_DRIVER=""
    GPU_USE_NVIDIA_OPEN="no"

    # Find discrete GPU first, fall back to integrated
    local gpu_line
    gpu_line=$(lspci -nn 2>/dev/null | grep -i 'vga\|3d\|display' | head -1) || true

    if [[ -z "${gpu_line}" ]]; then
        ewarn "No GPU detected via lspci"
        GPU_VENDOR="unknown"
        GPU_DRIVER="mesa-dri"
        export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER GPU_USE_NVIDIA_OPEN
        return
    fi

    einfo "GPU line: ${gpu_line}"

    # Extract vendor:device from [xxxx:yyyy]
    local pci_ids
    pci_ids=$(echo "${gpu_line}" | grep -o '\[[0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\]' | tail -1) || true
    local vendor_id device_id
    vendor_id=$(echo "${pci_ids}" | tr -d '[]' | cut -d: -f1)
    device_id=$(echo "${pci_ids}" | tr -d '[]' | cut -d: -f2)

    GPU_DEVICE_ID="${device_id}"

    # Determine GPU vendor name
    case "${vendor_id}" in
        "${GPU_VENDOR_NVIDIA}")
            GPU_VENDOR="nvidia"
            GPU_DEVICE_NAME=$(echo "${gpu_line}" | sed 's/.*: //')
            ;;
        "${GPU_VENDOR_AMD}")
            GPU_VENDOR="amd"
            GPU_DEVICE_NAME=$(echo "${gpu_line}" | sed 's/.*: //')
            ;;
        "${GPU_VENDOR_INTEL}")
            GPU_VENDOR="intel"
            GPU_DEVICE_NAME=$(echo "${gpu_line}" | sed 's/.*: //')
            ;;
        *)
            GPU_VENDOR="unknown"
            GPU_DEVICE_NAME="Unknown GPU"
            ;;
    esac

    # Get driver recommendation (driver|use_open_kernel)
    local recommendation
    recommendation=$(get_gpu_recommendation "${vendor_id}" "${device_id}")
    GPU_DRIVER=$(echo "${recommendation}" | cut -d'|' -f1)
    GPU_USE_NVIDIA_OPEN=$(echo "${recommendation}" | cut -d'|' -f2)

    export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER GPU_USE_NVIDIA_OPEN

    einfo "GPU: ${GPU_DEVICE_NAME} (${GPU_VENDOR})"
    einfo "Driver: ${GPU_DRIVER}"
    [[ "${GPU_VENDOR}" == "nvidia" ]] && einfo "NVIDIA open kernel: ${GPU_USE_NVIDIA_OPEN}"
}

# --- Disk Detection ---

# detect_disks — List available block devices
# Populates AVAILABLE_DISKS array: "device|size|model|transport"
detect_disks() {
    declare -ga AVAILABLE_DISKS=()

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local name size model tran
        read -r name size model tran <<< "${line}"
        AVAILABLE_DISKS+=("${name}|${size}|${model:-unknown}|${tran:-unknown}")
        einfo "Disk: /dev/${name} -- ${size} -- ${model:-unknown} (${tran:-unknown})"
    done < <(lsblk -dno NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v '^loop\|^sr\|^rom\|^ram\|^zram')

    export AVAILABLE_DISKS

    if [[ ${#AVAILABLE_DISKS[@]} -eq 0 ]]; then
        ewarn "No suitable disks detected"
    fi
}

# get_disk_list_for_dialog — Format disks for dialog menu
get_disk_list_for_dialog() {
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        echo "/dev/${name}"
        echo "${size} ${model} (${tran})"
    done
}

# --- ESP / Windows Detection ---

# detect_esp — Find existing EFI System Partitions
# Populates ESP_PARTITIONS array and checks for Windows
detect_esp() {
    declare -ga ESP_PARTITIONS=()
    WINDOWS_DETECTED=0
    WINDOWS_ESP=""

    while IFS= read -r block; do
        [[ -z "${block}" ]] && continue
        # Parse key=value pairs safely without eval
        local DEVNAME="" UUID="" TYPE="" PART_ENTRY_TYPE=""
        while IFS='=' read -r key val; do
            case "${key}" in
                DEVNAME)          DEVNAME="${val}" ;;
                UUID)             UUID="${val}" ;;
                TYPE)             TYPE="${val}" ;;
                PART_ENTRY_TYPE)  PART_ENTRY_TYPE="${val}" ;;
            esac
        done <<< "${block}"

        local dev="${DEVNAME}" type="${TYPE}" parttype="${PART_ENTRY_TYPE}"

        # Check for EFI System Partition (GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B)
        if [[ "${parttype:-}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || \
           [[ "${type:-}" == "vfat" && "${parttype:-}" == "c12a7328"* ]]; then
            ESP_PARTITIONS+=("${dev}")
            einfo "Found ESP: ${dev}"

            # Check for Windows Boot Manager
            local tmp_mount
            tmp_mount=$(mktemp -d /tmp/esp-check-XXXXXX)
            if mount -o ro "${dev}" "${tmp_mount}" 2>/dev/null; then
                if [[ -d "${tmp_mount}/EFI/Microsoft/Boot" ]]; then
                    WINDOWS_DETECTED=1
                    WINDOWS_ESP="${dev}"
                    einfo "Windows Boot Manager found on ${dev}"
                fi
                umount "${tmp_mount}" 2>/dev/null
            fi
            rmdir "${tmp_mount}" 2>/dev/null || true
        fi
    done < <(blkid -o export 2>/dev/null | awk -v RS='' '{print}' | \
             grep -i 'PART_ENTRY_TYPE.*c12a7328\|TYPE.*vfat' | head -20)

    # Simpler approach: iterate over all partitions
    if [[ ${#ESP_PARTITIONS[@]} -eq 0 ]]; then
        while IFS= read -r part; do
            local parttype
            parttype=$(blkid -o value -s PART_ENTRY_TYPE "${part}" 2>/dev/null) || continue
            if [[ "${parttype,,}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
                ESP_PARTITIONS+=("${part}")
                einfo "Found ESP: ${part}"

                local tmp_mount
                tmp_mount=$(mktemp -d /tmp/esp-check-XXXXXX)
                if mount -o ro "${part}" "${tmp_mount}" 2>/dev/null; then
                    if [[ -d "${tmp_mount}/EFI/Microsoft/Boot" ]]; then
                        WINDOWS_DETECTED=1
                        WINDOWS_ESP="${part}"
                        einfo "Windows Boot Manager found on ${part}"
                    fi
                    umount "${tmp_mount}" 2>/dev/null
                fi
                rmdir "${tmp_mount}" 2>/dev/null || true
            fi
        done < <(lsblk -lno PATH,FSTYPE 2>/dev/null | awk '$2=="vfat"{print $1}')
    fi

    export ESP_PARTITIONS WINDOWS_DETECTED WINDOWS_ESP
}

# --- Installed OS Detection ---

# detect_installed_oses — Scan partitions for installed operating systems
# Populates DETECTED_OSES associative array: partition -> OS name
detect_installed_oses() {
    declare -gA DETECTED_OSES=()
    LINUX_DETECTED=0

    einfo "Scanning for installed operating systems..."

    local part fstype
    while IFS=' ' read -r part fstype; do
        [[ -z "${part}" || -z "${fstype}" ]] && continue

        # Skip ESP partitions
        local esp
        for esp in "${ESP_PARTITIONS[@]}"; do
            [[ "${part}" == "${esp}" ]] && continue 2
        done

        case "${fstype}" in
            ext4|xfs)
                _detect_linux_on_partition "${part}" "${fstype}" ""
                ;;
            btrfs)
                _detect_linux_on_partition "${part}" "${fstype}" ""
                if [[ -z "${DETECTED_OSES[${part}]:-}" ]]; then
                    # btrfs fallback: try subvol=@  (openSUSE, Ubuntu)
                    _detect_linux_on_partition "${part}" "${fstype}" "@"
                fi
                ;;
            ntfs)
                _detect_ntfs_on_partition "${part}"
                ;;
        esac
    done < <(lsblk -lno PATH,FSTYPE 2>/dev/null | awk '$2 != "" {print}')

    export LINUX_DETECTED DETECTED_OSES

    # Log results
    if [[ ${#DETECTED_OSES[@]} -gt 0 ]]; then
        local p
        for p in "${!DETECTED_OSES[@]}"; do
            einfo "Detected OS: ${p} -> ${DETECTED_OSES[${p}]}"
        done
    else
        einfo "No other operating systems detected"
    fi

    serialize_detected_oses
}

# _detect_linux_on_partition — Try to find /etc/os-release on a Linux partition
# Args: partition fstype [subvol]
_detect_linux_on_partition() {
    local part="$1" fstype="$2" subvol="${3:-}"

    # Check if already mounted
    local existing_mount
    existing_mount=$(findmnt -n -o TARGET "${part}" 2>/dev/null | head -1) || true

    local tmp_mount="" needs_umount=0
    if [[ -n "${existing_mount}" ]]; then
        tmp_mount="${existing_mount}"
    else
        tmp_mount="/tmp/os-detect-$$"
        mkdir -p "${tmp_mount}"

        local mount_opts="-o ro"
        [[ -n "${subvol}" ]] && mount_opts="-o ro,subvol=${subvol}"

        if ! mount ${mount_opts} "${part}" "${tmp_mount}" 2>/dev/null; then
            rmdir "${tmp_mount}" 2>/dev/null || true
            return
        fi
        needs_umount=1
    fi

    if [[ -f "${tmp_mount}/etc/os-release" ]]; then
        local pretty_name
        pretty_name=$(sed -n 's/^PRETTY_NAME="\?\([^"]*\)"\?$/\1/p' "${tmp_mount}/etc/os-release" | head -1) || true
        if [[ -n "${pretty_name}" ]]; then
            DETECTED_OSES["${part}"]="${pretty_name}"
            LINUX_DETECTED=1
        fi
    fi

    if [[ "${needs_umount}" -eq 1 ]]; then
        umount "${tmp_mount}" 2>/dev/null || true
        rmdir "${tmp_mount}" 2>/dev/null || true
    fi
}

# _detect_ntfs_on_partition — Check if NTFS partition is a Windows system drive
_detect_ntfs_on_partition() {
    local part="$1"

    local existing_mount
    existing_mount=$(findmnt -n -o TARGET "${part}" 2>/dev/null | head -1) || true

    local tmp_mount="" needs_umount=0
    if [[ -n "${existing_mount}" ]]; then
        tmp_mount="${existing_mount}"
    else
        tmp_mount="/tmp/os-detect-$$"
        mkdir -p "${tmp_mount}"

        if ! mount -o ro "${part}" "${tmp_mount}" 2>/dev/null; then
            rmdir "${tmp_mount}" 2>/dev/null || true
            return
        fi
        needs_umount=1
    fi

    if [[ -d "${tmp_mount}/Windows/System32" ]]; then
        DETECTED_OSES["${part}"]="Windows (system)"
        WINDOWS_DETECTED=1
        export WINDOWS_DETECTED
    fi

    if [[ "${needs_umount}" -eq 1 ]]; then
        umount "${tmp_mount}" 2>/dev/null || true
        rmdir "${tmp_mount}" 2>/dev/null || true
    fi
}

# serialize_detected_oses — DETECTED_OSES assoc array -> serialized string
# Format: "/dev/sda1=Windows|/dev/sda3=openSUSE Tumbleweed"
serialize_detected_oses() {
    local result="" part
    for part in "${!DETECTED_OSES[@]}"; do
        local name="${DETECTED_OSES[${part}]}"
        # Sanitize: replace | and = in OS names with -
        name="${name//|/-}"
        name="${name//=/-}"
        [[ -n "${result}" ]] && result+="|"
        result+="${part}=${name}"
    done
    DETECTED_OSES_SERIALIZED="${result}"
    export DETECTED_OSES_SERIALIZED
}

# deserialize_detected_oses — Serialized string -> DETECTED_OSES assoc array
# Restores WINDOWS_DETECTED and LINUX_DETECTED flags
deserialize_detected_oses() {
    declare -gA DETECTED_OSES=()
    WINDOWS_DETECTED="${WINDOWS_DETECTED:-0}"
    LINUX_DETECTED="${LINUX_DETECTED:-0}"

    local serialized="${DETECTED_OSES_SERIALIZED:-}"
    [[ -z "${serialized}" ]] && return 0

    local IFS='|'
    local entry
    for entry in ${serialized}; do
        local part="${entry%%=*}"
        local name="${entry#*=}"
        [[ -z "${part}" || -z "${name}" ]] && continue
        DETECTED_OSES["${part}"]="${name}"

        # Restore flags
        if [[ "${name}" == *"Windows"* ]]; then
            WINDOWS_DETECTED=1
        else
            LINUX_DETECTED=1
        fi
    done

    export DETECTED_OSES WINDOWS_DETECTED LINUX_DETECTED
}

# --- Full Detection ---

# detect_all_hardware — Run all hardware detection
detect_all_hardware() {
    einfo "=== Hardware Detection ==="
    detect_cpu
    detect_gpu
    detect_disks
    detect_esp
    detect_installed_oses
    einfo "=== Hardware Detection Complete ==="
}

# get_hardware_summary — Format hardware info for display
get_hardware_summary() {
    local summary=""
    summary+="CPU: ${CPU_MODEL:-unknown}\n"
    summary+="  Cores: ${CPU_CORES:-?}\n"
    summary+="\n"
    summary+="GPU: ${GPU_DEVICE_NAME:-unknown}\n"
    summary+="  Vendor: ${GPU_VENDOR:-unknown}\n"
    summary+="  Driver: ${GPU_DRIVER:-none}\n"
    [[ "${GPU_VENDOR:-}" == "nvidia" ]] && summary+="  Open kernel: ${GPU_USE_NVIDIA_OPEN:-no}\n"
    summary+="\n"
    summary+="Disks:\n"
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        summary+="  /dev/${name}: ${size} ${model} (${tran})\n"
    done
    summary+="\n"
    if [[ ${#ESP_PARTITIONS[@]} -gt 0 ]]; then
        summary+="ESP partitions: ${ESP_PARTITIONS[*]}\n"
    fi
    summary+="\n"
    if [[ ${#DETECTED_OSES[@]} -gt 0 ]]; then
        summary+="Detected operating systems:\n"
        local p
        for p in "${!DETECTED_OSES[@]}"; do
            summary+="  ${p}: ${DETECTED_OSES[${p}]}\n"
        done
    else
        summary+="Detected operating systems: none\n"
    fi
    echo -e "${summary}"
}
