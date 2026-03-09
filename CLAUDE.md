# CLAUDE.md — Project context for Claude Code

## What this is

Interactive TUI installer for Void Linux written in Bash. Goal: clone the repo from any live ISO, run `./install.sh` and be guided through the entire process from disk partitioning to a working KDE Plasma desktop. After a crash: `./install.sh --resume` scans disks and resumes from the last checkpoint.

## Architecture

### Two-process model

1. **Outer process** (`install.sh --install`) — disks, ROOTFS, chroot preparation
2. **Inner process** (`install.sh __chroot_phase`) — XBPS update, kernel, desktop, bootloader
3. The installer copies itself into the chroot (`/tmp/void-installer`) and re-invokes itself

### File structure

```
install.sh              — Entry point, argument parsing, phase orchestration
configure.sh            — Wrapper: exec install.sh --configure

lib/                    — Library modules (NEVER execute directly)
├── protection.sh       — Guard: checks $_VOID_INSTALLER
├── constants.sh        — Global constants, paths, CONFIG_VARS[], CHECKPOINTS[]
├── logging.sh          — elog/einfo/ewarn/eerror/die/die_trace, colors, log to file
├── utils.sh            — try (interactive recovery, text fallback without dialog, LIVE_OUTPUT via tee), checkpoint_set/reached/validate/migrate_to_target, is_root/is_efi/has_network/ensure_dns, generate_password_hash, try_resume_from_disk, infer_config_from_partition
├── dialog.sh           — Wrapper gum/dialog/whiptail, primitives (msgbox/yesno/menu/radiolist/checklist/gauge/infobox/inputbox/passwordbox), wizard runner (register_wizard_screens + run_wizard), bundled gum extraction
├── config.sh           — config_save/load/set/get/dump/diff (${VAR@Q} quoting), validate_config()
├── hardware.sh         — detect_cpu/gpu(multi-GPU/hybrid)/disks/esp/installed_oses, detect_asus_rog, detect_bluetooth/fingerprint/thunderbolt/sensors/webcam/wwan, serialize/deserialize_detected_oses, get_hardware_summary
├── disk.sh             — Two-phase: disk_plan_add/add_stdin/show/auto/dualboot → cleanup_target_disk + disk_execute_plan (sfdisk), mount/unmount_filesystems, get_uuid/get_partuuid, shrink helpers (disk_plan_shrink)
├── network.sh          — check_network, install_network_manager, select_fastest_mirror
├── rootfs.sh           — rootfs_get_url/download/verify/extract (_find_rootfs_file for resume)
├── xbps.sh             — xbps_configure_mirror/nonfree, xbps_update (base-voidstrap → base-system swap), xbps_install_base, install_extra_packages, install_fingerprint_tools, install_thunderbolt_tools, install_sensor_tools, install_wwan_tools, install_asusctl_tools
├── kernel.sh           — kernel_install (mainline vs lts, firmware, microcode)
├── bootloader.sh       — bootloader_install, _configure_grub, _mount_other_oses_for_osprober, _verify_grub_config, _verify_efi_entries
├── system.sh           — system_set_timezone/locale/hostname/keymap, generate_fstab, install_filesystem_tools, system_create_users, system_finalize, _enable_service
├── desktop.sh          — desktop_install (GPU drivers, KDE Plasma, SDDM, elogind, PipeWire, KDE apps)
├── swap.sh             — swap_setup (zramen, partition, swap file)
├── chroot.sh           — chroot_setup/teardown/exec, copy_dns_info, copy_installer_to_chroot
├── hooks.sh            — maybe_exec 'before_X' / 'after_X'
└── preset.sh           — preset_export/import (hardware overlay)

tui/                    — TUI screens
├── welcome.sh          — screen_welcome: branding + prereq check
├── preset_load.sh      — screen_preset_load: skip/file/browse
├── hw_detect.sh        — screen_hw_detect: detect_all_hardware + summary (infobox auto-advance)
├── disk_select.sh      — screen_disk_select: disk + scheme (auto/dual-boot/manual) + _shrink_wizard()
├── filesystem_select.sh — screen_filesystem_select: ext4/btrfs/xfs + btrfs subvolumes
├── swap_config.sh      — screen_swap_config: zram/partition/file/none
├── network_config.sh   — screen_network_config: hostname + mirror
├── locale_config.sh    — screen_locale_config: timezone + locale + keymap
├── kernel_select.sh    — screen_kernel_select: mainline/lts
├── gpu_config.sh       — screen_gpu_config: auto/nvidia/amd/intel/none + nvidia-open + hybrid GPU display
├── desktop_config.sh   — screen_desktop_config: KDE apps checklist
├── user_config.sh      — screen_user_config: root pwd, user, groups
├── extra_packages.sh   — screen_extra_packages: checklist (fastfetch, btop, kitty + conditional hw items) + freeform text
├── preset_save.sh      — screen_preset_save: optional export
├── summary.sh          — screen_summary: validate_config + full summary + "YES" + countdown
└── progress.sh         — screen_progress: resume detection + infobox (short phases) + live terminal (chroot)

data/                   — Static databases + bundled assets
├── gpu_database.sh     — nvidia_generation(), get_gpu_recommendation(), get_hybrid_gpu_recommendation()
├── mirrors.sh          — VOID_MIRRORS[], get_mirror_list_for_dialog()
├── dialogrc            — Dark TUI theme (loaded by DIALOGRC in init_dialog)
└── gum.tar.gz          — Bundled gum v0.17.0 binary (static ELF x86-64, ~4.5 MB)

presets/                — Example configurations
tests/                  — Tests (bash, standalone)
hooks/                  — *.sh.example
TODO.md                 — Planned improvements
```

### TUI screen conventions

Each screen is a `screen_*()` function that returns:
- `0` (`TUI_NEXT`) — proceed forward
- `1` (`TUI_BACK`) — go back
- `2` (`TUI_ABORT`) — abort

`run_wizard()` in `lib/dialog.sh` manages the screen index based on return code. Cancel in any dialog is treated as `TUI_BACK`.

### Configuration variables

All config variables are defined in `CONFIG_VARS[]` in `lib/constants.sh`:

| Variable | Values | Description |
|---|---|---|
| `TARGET_DISK` | /dev/sda, /dev/nvme0n1, ... | Target disk device |
| `PARTITION_SCHEME` | auto/dual-boot/manual | Partitioning strategy |
| `FILESYSTEM` | ext4/btrfs/xfs | Root filesystem type |
| `BTRFS_SUBVOLUMES` | colon-separated pairs | e.g. `@:/:@home:/home:@var:/var` |
| `SWAP_TYPE` | zram/partition/file/none | Swap configuration method |
| `SWAP_SIZE_MIB` | integer | Size for partition or file swap |
| `HOSTNAME` | string | System hostname (RFC 1123) |
| `MIRROR_URL` | URL | XBPS repository mirror |
| `TIMEZONE` | Region/City | e.g. `Europe/Warsaw` |
| `LOCALE` | locale string | e.g. `en_US.UTF-8` |
| `KEYMAP` | keymap name | e.g. `us`, `pl` |
| `KERNEL_TYPE` | mainline/lts | Kernel flavor |
| `GPU_VENDOR` | nvidia/amd/intel/none/unknown | Detected or selected GPU |
| `GPU_DRIVER` | nvidia/mesa-dri | Driver package recommendation |
| `GPU_USE_NVIDIA_OPEN` | yes/no | Use open kernel module (Turing+) |
| `DESKTOP_EXTRAS` | space-separated | KDE apps: firefox, thunderbird, etc. |
| `ROOT_PASSWORD_HASH` | SHA-512 hash | Root password (never plaintext) |
| `USERNAME` | string | Regular user login |
| `USER_PASSWORD_HASH` | SHA-512 hash | User password (never plaintext) |
| `USER_GROUPS` | comma-separated | e.g. `wheel,audio,video,input,storage,network` |
| `EXTRA_PACKAGES` | space-separated | Additional XBPS packages |
| `ENABLE_NONFREE` | yes/no | Enable nonfree XBPS repository |
| `ESP_PARTITION` | /dev/sdX1 | EFI System Partition device |
| `ESP_REUSE` | yes/no | Reuse existing ESP (dual-boot) |
| `ROOT_PARTITION` | /dev/sdX2 | Root filesystem partition device |
| `SWAP_PARTITION` | /dev/sdX3 | Swap partition device (if applicable) |
| `BOOT_PARTITION` | /dev/sdX... | Separate /boot (if applicable) |
| `WINDOWS_DETECTED` | 0/1 | Auto-detected Windows installation |
| `LINUX_DETECTED` | 0/1 | Auto-detected Linux installation |
| `DETECTED_OSES_SERIALIZED` | serialized map | partition=OS name pairs |
| `HYBRID_GPU` | yes/no | Hybrid iGPU+dGPU detected |
| `IGPU_VENDOR` | intel/amd | Integrated GPU vendor |
| `IGPU_DEVICE_NAME` | string | Integrated GPU name |
| `DGPU_VENDOR` | nvidia/amd | Discrete GPU vendor |
| `DGPU_DEVICE_NAME` | string | Discrete GPU name |
| `ASUS_ROG_DETECTED` | 0/1 | ASUS ROG/TUF laptop detected |
| `ENABLE_ASUSCTL` | yes/no | Install asusctl (ROG) |
| `BLUETOOTH_DETECTED` | 0/1 | Bluetooth hardware detected |
| `FINGERPRINT_DETECTED` | 0/1 | Fingerprint reader detected |
| `ENABLE_FINGERPRINT` | yes/no | fprintd enabled (opt-in) |
| `THUNDERBOLT_DETECTED` | 0/1 | Thunderbolt controller detected |
| `ENABLE_THUNDERBOLT` | yes/no | bolt enabled (opt-in) |
| `SENSORS_DETECTED` | 0/1 | IIO sensors detected |
| `ENABLE_SENSORS` | yes/no | iio-sensor-proxy enabled (opt-in) |
| `WEBCAM_DETECTED` | 0/1 | Webcam detected |
| `WWAN_DETECTED` | 0/1 | WWAN/LTE modem detected |
| `ENABLE_WWAN` | yes/no | ModemManager enabled (opt-in) |
| `SHRINK_PARTITION` | /dev/sdXN | Partition to shrink (dual-boot) |
| `SHRINK_PARTITION_FSTYPE` | ntfs/ext4/btrfs | Filesystem of partition to shrink |
| `SHRINK_NEW_SIZE_MIB` | integer | New size after shrink (MiB) |

### Void-specific patterns

#### XBPS package management

Void uses XBPS (X Binary Package System), not portage or apt:
- `xbps-install -Syu` — sync repos and update all packages
- `xbps-install -y <pkg>` — install package (non-interactive)
- `xbps-remove -y <pkg>` — remove package
- `xbps-query <pkg>` — check if installed
- `xbps-reconfigure -f <pkg>` — reconfigure a package (triggers hooks)
- `xbps-reconfigure -fa` — reconfigure all packages (important at finalize)

Mirror configuration lives in `/etc/xbps.d/` as `.conf` files:
- `00-repository-main.conf` — `repository=https://mirror/current`
- `10-repository-nonfree.conf` — `repository=https://mirror/current/nonfree`

#### Runit service management

Void uses runit, not systemd or OpenRC. Services are enabled by creating symlinks:
```bash
ln -sf /etc/sv/<service> /var/service/<service>
```
Services are disabled by removing the symlink. No `systemctl enable` or `rc-update add`.

Essential services enabled by the installer:
- `agetty-tty1`, `agetty-tty2`, `agetty-tty3` — virtual consoles
- `udevd` — device manager
- `dbus` — message bus (required by KDE)
- `sddm` — display manager
- `elogind` — session manager (required by KDE on runit)
- `NetworkManager` — network management
- `zramen` — zram swap (if SWAP_TYPE=zram)

#### base-voidstrap to base-system swap

The ROOTFS tarball contains `base-voidstrap` (minimal bootstrap package). During `xbps_update()`, the installer:
1. Updates XBPS itself (`xbps-install -Syu xbps`)
2. Full system update (`xbps-install -Syu`)
3. Installs `base-system` (full base meta-package)
4. Removes `base-voidstrap` (superseded by base-system)

This transition is critical — skipping it leaves the system with a minimal package set.

#### Nonfree repository

NVIDIA proprietary drivers require the nonfree repository. The installer:
- Asks via `ENABLE_NONFREE` config variable
- Writes `10-repository-nonfree.conf` to `/etc/xbps.d/`
- Auto-enables nonfree if NVIDIA GPU is selected (even if user said no)

#### elogind requirement for KDE

KDE Plasma on Void (runit) requires `elogind` for session management. Without it, KDE cannot manage permissions, power actions, or seat allocation. The installer installs and enables elogind alongside KDE.

#### /etc/rc.conf for hostname and keymap

Void uses `/etc/rc.conf` for system-wide settings. The installer writes:
- `KEYMAP="<keymap>"` — console keymap
- Also writes `/etc/vconsole.conf` for compatibility
- Hostname goes to `/etc/hostname` (standard) + `/etc/hosts`
- `/etc/rc.conf` may also contain `HOSTNAME=` and `TIMEZONE=` (used by config inference)

#### /etc/default/libc-locales for locale

Void glibc generates locales via `/etc/default/libc-locales`:
1. Uncomment desired locale (e.g. `pl_PL.UTF-8 UTF-8`)
2. Always enable `en_US.UTF-8` as fallback
3. Run `xbps-reconfigure -f glibc-locales` to generate
4. Write `LANG=<locale>` to `/etc/locale.conf`

#### grub-x86_64-efi package name

Void's GRUB package for EFI is `grub-x86_64-efi` (not `grub` or `grub2`). The installer also installs `efibootmgr` and optionally `os-prober` for dual-boot.

#### zramen for zram swap

Void uses `zramen` package (not `zram-generator` or `zram-init` from other distros). It provides a runit service that creates zram devices at boot. Enable with: `ln -sf /etc/sv/zramen /var/service/zramen`.

#### Kernel packages

Two kernel flavors are available:
- `linux` + `linux-headers` — mainline kernel (default, rolling)
- `linux-lts` + `linux-lts-headers` — LTS kernel (stable)

Firmware is installed via `linux-firmware`, `linux-firmware-amd`, `linux-firmware-intel`, `linux-firmware-nvidia`. Intel microcode is installed as `intel-ucode` (not `intel-microcode`). AMD microcode is bundled in `linux-firmware`.

#### GPU drivers

| GPU | Packages | Notes |
|---|---|---|
| NVIDIA | `nvidia` (from nonfree) | Requires nonfree repo, DRM KMS configured via modprobe.d |
| AMD | `mesa-dri vulkan-loader mesa-vulkan-radeon` | Open source mesa stack |
| Intel | `mesa-dri vulkan-loader mesa-vulkan-intel intel-video-accel` | Open source mesa + VA-API |

NVIDIA DRM KMS is configured via `/etc/modprobe.d/nvidia.conf` with `options nvidia_drm modeset=1 fbdev=1`. Module loading is configured in `/etc/modules-load.d/nvidia.conf`.

#### ROOTFS (not stage3)

Void uses ROOTFS tarballs (not stage3 like Gentoo). Published at `https://repo-default.voidlinux.org/live/current/`. Verification uses SHA256 (from `sha256sum.txt`), not GPG-signed DIGESTS.

### Two-phase disk operations

1. `disk_plan_auto()` / `disk_plan_dualboot()` — builds `DISK_ACTIONS[]` + `DISK_STDIN[]`
2. `disk_execute_plan()` — iterates and executes via `try` (stdin piped for sfdisk)

Partitioning uses `sfdisk` (util-linux) — atomic stdin script instead of sequential calls. A single `sfdisk` command creates the GPT label + all partitions at once. `disk_plan_add_stdin()` stores stdin data in `DISK_STDIN[]` (parallel array to `DISK_ACTIONS[]`).

### Checkpoints

`checkpoint_set "name"` creates a file in `$CHECKPOINT_DIR`. `checkpoint_reached "name"` checks for it. After mounting the target disk, `checkpoint_migrate_to_target()` moves checkpoints from `/tmp` to `${MOUNTPOINT}/tmp/void-installer-checkpoints/` — they disappear automatically when the disk is reformatted.

Resume after crash: `screen_progress()` checks for existing checkpoints and asks the user whether to resume. `checkpoint_validate()` verifies phase artifacts (e.g. whether ROOTFS is extracted, whether kernel is installed) — invalid checkpoints are removed.

**`--resume` mode**: `try_resume_from_disk()` in `lib/utils.sh` scans partitions (ext4/xfs/btrfs) looking for checkpoints and config. Returns: 0 = config + checkpoints, 1 = only checkpoints, 2 = nothing found. `_save_config_to_target()` in `tui/progress.sh` saves config to the target disk after the partitioning phase — so `--resume` can recover it.

**Config inference (rc=1)**: When `--resume` finds checkpoints but no config, `infer_config_from_partition()` in `lib/utils.sh` reads configuration from files on the target partition:
- `/etc/fstab` — partitions, filesystem, swap
- `/etc/xbps.d/*.conf` — mirror URL, nonfree repo
- `/etc/rc.conf` — hostname, keymap, timezone
- `/etc/hostname` — hostname (fallback)
- `/etc/timezone` or `/etc/localtime` symlink — timezone (fallback)
- `/etc/default/libc-locales` — locale
- `/etc/vconsole.conf` — keymap (fallback)
- `/var/db/xbps/.linux-lts-*` or `.linux-*` — kernel type
- `/etc/sv/zramen`, `/var/service/zramen` — zram swap detection
- `/var/swapfile` — swap file detection

Returns 0 if sufficient (ROOT_PARTITION, ESP_PARTITION, FILESYSTEM, TARGET_DISK), 1 if not — then the wizard is launched with pre-filled values. Testing: `_RESUME_TEST_DIR` + `_INFER_UUID_MAP` (fake filesystem instead of real mount/blkid).

### Function `try`

`try "description" command args...` — on failure displays a Retry/Shell/Continue/Log/Abort menu. Every command that can fail MUST go through `try`.

Two modes of operation:
- **Normal**: command output goes to log file (silent). Dialog UI for recovery menu.
- **`LIVE_OUTPUT=1`**: command output goes to `tee` (terminal + log). Set during chroot phase.

When `dialog` is not available (e.g. inside fresh chroot), `try()` uses a simple text menu: `(r)etry | (s)hell | (c)ontinue | (a)bort`.

### gum TUI backend

Third TUI backend alongside `dialog` and `whiptail`. Static binary bundled in repo as `data/gum.tar.gz` (gum v0.17.0, ~4.5 MB). Zero network dependencies.

- `_extract_bundled_gum()` extracts to `/tmp/void-installer-gum/gum`, verifies `gum --version`
- Detection priority: gum > dialog > whiptail. Opt-out: `GUM_BACKEND=0`
- Desc→tag mapping via parallel arrays (gum 0.17.0 `--label-delimiter` is broken)
- Phantom ESC detection: `EPOCHREALTIME` with 150ms threshold, 3 retries then text fallback
- Terminal response handling: `COLORFGBG="15;0"`, `stty -echo`, `_gum_drain_tty()`

### Hybrid GPU & ASUS ROG detection

`detect_gpu()` scans ALL GPUs from `lspci -nn` (not just `head -1`). Classification:
- NVIDIA = always dGPU; Intel = always iGPU; AMD — if NVIDIA also present then iGPU, otherwise single
- PCI slot heuristic: bus `00` = iGPU, `01+` = dGPU
- When 2 GPUs: `HYBRID_GPU=yes`, `IGPU_*`, `DGPU_*` set, `GPU_VENDOR`=dGPU vendor
- `GPU_DRIVER` via `get_hybrid_gpu_recommendation()` in `data/gpu_database.sh`

ASUS ROG detection: `detect_asus_rog()` — DMI sysfs. Sets `ASUS_ROG_DETECTED=0/1`.

### Peripheral detection

6 detection functions in `lib/hardware.sh`, called from `detect_all_hardware()`:
- `detect_bluetooth()` — `/sys/class/bluetooth/hci*`
- `detect_fingerprint()` — USB vendor IDs (06cb, 27c6, 147e, 138a, 04f3)
- `detect_thunderbolt()` — sysfs + lspci
- `detect_sensors()` — IIO sysfs
- `detect_webcam()` — `/sys/class/video4linux/video*/name`
- `detect_wwan()` — `lspci -nnd 8086:7360`

Opt-in in `tui/extra_packages.sh` checklist (visible only when detected):
- Fingerprint → fprintd, Thunderbolt → bolt, IIO sensors → iio-sensor-proxy, WWAN → ModemManager
- Bluetooth → auto-installed with desktop (`_install_bluetooth()` in `lib/desktop.sh`)

### Partition shrink wizard

When dual-boot selected and not enough free space, `_shrink_wizard()` in `tui/disk_select.sh` offers to shrink an existing partition:
- Supported: NTFS (ntfsresize), ext4 (resize2fs), btrfs (btrfs filesystem resize)
- Safety: 1 GiB margin, minimum VOID_MIN_SIZE_MIB (10 GiB)
- Helpers in `lib/disk.sh`: `disk_get_free_space_mib()`, `disk_get_partition_size_mib()`, `disk_get_partition_used_mib()`, `disk_can_shrink_fstype()`, `disk_plan_shrink()`

### Config validation

`validate_config()` in `lib/config.sh` — validates config BEFORE install. Called at entry to `screen_summary()`.
Checks: required variables, enum values (KERNEL_TYPE ∈ {mainline, lts}, FILESYSTEM ∈ {ext4, btrfs, xfs}), hostname RFC 1123, block device existence, cross-field consistency.

## Running tests

```bash
bash tests/test_config.sh        # Config round-trip
bash tests/test_hardware.sh      # GPU database
bash tests/test_disk.sh          # Disk planning dry-run with sfdisk
bash tests/test_checkpoint.sh    # Checkpoint validate + migrate
bash tests/test_resume.sh        # Resume from disk scanning + recovery
bash tests/test_multiboot.sh     # Multi-boot OS detection + serialization
bash tests/test_infer_config.sh  # Config inference from installed system
```

All tests are standalone — they do not require root or hardware. They use `DRY_RUN=1` and `NON_INTERACTIVE=1`.

## Known patterns and pitfalls

- `(( var++ ))` at var=0 returns exit 1 under `set -e` — always add `|| true`
- `lib/constants.sh` uses `: "${VAR:=default}"` instead of `readonly` so tests can override values
- `lib/protection.sh` checks `$_VOID_INSTALLER` — tests must export this
- `config_save` uses `${VAR@Q}` (bash 4.4+) for safe quoting, creates files with `umask 077` (contains password hashes)
- `config_load` sources a filtered temp file (only known CONFIG_VARS), not raw input — prevents injection
- Dialog: `2>&1 >/dev/tty` (dialog) vs `3>&1 1>&2 2>&3` (whiptail) — both handled in `lib/dialog.sh`
- Files in lib/ are NEVER executed directly — always sourced
- **`$*` vs `"$@"` vs `printf '%q '`**: When a command is built as a string and later executed via `bash -c`, `$*` loses quoting of arguments with spaces (e.g. `"EFI System Partition"` becomes three separate tokens). Solution: `printf '%q ' "$@"` preserves quoting. Applies to: `disk_plan_add()`, `disk_plan_add_stdin()`, `chroot_exec()`, `dialog_prgbox()`. Direct execution (`"$@"`) does not have this problem (e.g. `try()` line 23).
- **Variable interpolation in strings of other languages**: Do not insert bash variables directly into Python/Perl code (e.g. `python3 -c "...('${password}')..."`). Special characters can break syntax or enable injection. Pass via environment variables (`VOID_PW="${password}" python3 -c "...os.environ['VOID_PW']..."`).
- **Void ROOTFS SHA256 verification**: Void publishes a single `sha256sum.txt` file (not GPG-signed DIGESTS like Gentoo). The file contains SHA256 hashes for all live images and ROOTFS tarballs. Parse with `sed` to extract the correct filename — the ROOTFS filename includes a date stamp (`void-x86_64-ROOTFS-20240314.tar.xz`).
- **Checkpoints on target disk**: After mounting the target disk, checkpoints are migrated from `/tmp` to `${MOUNTPOINT}/tmp/void-installer-checkpoints/`. Reformatting the disk automatically erases checkpoints. On resume, `checkpoint_validate()` verifies artifacts before skipping a phase.
- **stderr redirect and dialog UI**: When stderr is redirected to log file (`exec 2>>LOG`), `dialog` is invisible (it writes to stderr). `try()` must temporarily restore stderr (fd 4) to show the recovery menu. Pattern: `if { true >&4; } 2>/dev/null; then exec 2>&4; fi`.
- **`dialog` missing in chroot**: Fresh ROOTFS may not have `dialog`. `try()` must have a text fallback (`read -r` from `/dev/tty`) instead of `dialog_menu`. Check: `command -v "${DIALOG_CMD:-dialog}"`.
- **`set -euo pipefail` + `grep` in `$()`**: `grep` returns exit 1 on no match. With `pipefail` the entire pipeline fails. Effect: `var=$(cmd | grep pattern | head -1)` kills the script BEFORE reaching `if [[ -z "$var" ]]`. Solution: `|| true` at the end of `$()`.
- **Partitions from previous installation block `sfdisk`**: On reinstallation, target disk partitions may still be mounted. `sfdisk` refuses to write if partitions are in use. Solution: `cleanup_target_disk()` unmounts all partitions and deactivates swap before `disk_execute_plan()`.
- **Hostname validation**: Hostname goes to `/etc/hostname` and `/etc/hosts`. Validate with RFC 1123 regex: `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`.
- **`eval` on external data**: Do not use `eval "${line}"` on `blkid` output or config files. A malicious partition label can contain code. Parse via `case`/`read` or `declare`.
- **`try_resume_from_disk()` returns 0/1/2, not boolean**: 0 = config + checkpoints, 1 = only checkpoints, 2 = nothing. Testing: `_RESUME_TEST_DIR` switches to fake directories instead of real mount. Do not use `if try_resume_from_disk` — always `rc=0; try_resume_from_disk || rc=$?; case ${rc}`.
- **DNS on Live ISO**: Live ISO may not have DNS configured. `ensure_dns()` in preflight automatically adds `8.8.8.8` if ping by IP works but by name does not.
- **Dialog theme**: `data/dialogrc` loaded by `export DIALOGRC=` in `init_dialog()`. Whiptail ignores DIALOGRC. Gum uses `GUM_CHOOSE_*`/`GUM_INPUT_*` env vars.
- **gum TUI backend**: `data/gum.tar.gz` extracted by `_extract_bundled_gum()` to `/tmp/void-installer-gum/`. Opt-out: `GUM_BACKEND=0`. Priority: gum > dialog > whiptail.
- **Phantom ESC in gum**: gum/termenv sends OSC 11 (background color query) and CPR. `COLORFGBG="15;0"` suppresses OSC 11. `EPOCHREALTIME` with 150ms threshold detects phantom ESC from terminal responses vs real user ESC.
- **ESP mount path**: ESP is mounted at `/boot/efi` consistently (disk.sh, bootloader.sh, system.sh fstab).
- **`ROOTFS_FILE` unbound on resume**: When the `rootfs_download` checkpoint survived but the phase is skipped, `ROOTFS_FILE` is not set. `rootfs_verify()`/`rootfs_extract()` use `_find_rootfs_file()` for fallback — searches for `void-x86_64-ROOTFS-*.tar.xz` on `MOUNTPOINT`.
- **Passwords/hashes NEVER in command arguments**: `openssl passwd -6 "${password}"` and `usermod -p "${hash}"` are visible in `ps aux`. Use: `openssl passwd -6 -stdin <<< "${password}"` and `bash -c 'echo "user:$1" | chpasswd -e' -- "${hash}"`.
- **`eval echo "~${user}"` leads to injection**: Use `getent passwd "${user}" | cut -d: -f6` instead.
- **`xbps-reconfigure -fa` at finalize**: This reconfigures ALL installed packages, triggering post-install hooks (initramfs generation, locale generation, etc.). This is the Void equivalent of Gentoo's `dispatch-conf` + `env-update`. Must run at the very end.
- **elogind vs ConsoleKit**: KDE on Void requires elogind (or systemd-logind). ConsoleKit is deprecated and does not work with modern KDE. Always install `elogind` with KDE and enable the runit service.
- **SDDM tty conflict**: SDDM manages its own TTY. The installer removes `/var/service/agetty-tty7` to prevent conflicts. If agetty grabs tty7 before SDDM, the display manager fails to start.
- **PipeWire autostart**: PipeWire on Void (runit) does not have a system-wide runit service. It starts per-user via XDG autostart or KDE session management. The installer copies the default config from `/usr/share/pipewire/pipewire.conf` to `/etc/pipewire/`.
- **btrfs swap file**: btrfs requires `btrfs filesystem mkswapfile` instead of `dd` + `mkswap`. Regular swap files on btrfs cause filesystem corruption. The installer checks `FILESYSTEM` before creating swap files.
- **Killing `tee` can cascade-kill the current command**: When `try()` uses `| tee`, killing the `tee` process causes a broken pipe leading to SIGPIPE to the command. Effect: the command dies mid-work. Do NOT kill tee during ongoing operations — wait until it hangs (no activity in `top`).
- **Exit code `0` on actual error in `try()`**: After `if cmd; then ...; fi` without `else`, bash sets `$?` to 0 regardless of the command's exit code ("if no condition tested true" implies exit 0). Effect: `try()` displays "Failed (exit 0)" despite an actual error. Cosmetic bug — error detection works correctly.
- **`infer_config_from_partition` and testing**: When `_RESUME_TEST_DIR` is set, `infer_config_from_partition` uses `_RESUME_TEST_DIR/mnt/<part>` instead of real mount. UUID resolver (`_resolve_uuid`) reads from `_INFER_UUID_MAP` file instead of `blkid -U`.
- **`_infer_kernel_type` checks `/var/db/xbps/`**: XBPS package database lives in `/var/db/xbps/`. Installed package plist files follow the pattern `.linux-lts-6.1.XXX_1.x86_64.plist`. The inference function uses `ls` patterns to detect kernel type.
- **NVIDIA on Void requires nonfree repo**: The `nvidia` driver package is in the nonfree repository. If the user selects NVIDIA but didn't enable nonfree, `_install_nvidia_drivers()` auto-enables the nonfree repo to prevent a confusing install failure.
- **Dual-boot partition detection with `sfdisk --append`**: When creating a new partition in free space for dual-boot, `sfdisk --append` may assign a different partition number than expected. After `disk_execute_plan()`, the installer verifies `ROOT_PARTITION` exists and re-scans if necessary.
- **os-prober mount/unmount cycle**: For accurate GRUB dual-boot detection, other OS partitions must be mounted before `grub-mkconfig`. The installer mounts detected OS partitions read-only in `/mnt/osprober-*`, runs grub-mkconfig, then unmounts them. Missing this step causes os-prober to miss Windows/Linux entries.
- **`blkid` parsing without `eval`**: The ESP detection code in `hardware.sh` parses `blkid -o export` output line-by-line using `read` and `case` instead of `eval` — safe against injection via partition labels.

## Debugging during live installation

Void Live ISO provides access to multiple TTYs (`Ctrl+Alt+F1`..`F6`). TTY1 = installer, TTY2-6 = free consoles. SSH on Live ISO can be configured manually.

### Multi-boot safety

The installer detects installed OSes (Windows, Linux) by scanning partitions. Results are stored in `DETECTED_OSES[]` (assoc array) and serialized to `DETECTED_OSES_SERIALIZED` for config save/load.

Safeguards:
- Dual-boot offered when Windows OR another Linux is detected (not only Windows)
- Partitions in the menu show: size, fstype, label, [OS name]
- Selecting a partition with an OS requires typing `ERASE`
- Summary in dual-boot mode requires `YES` and shows what will survive
- GRUB: os-prober mounts other OSes, grub.cfg verification, EFI entry verification
- `efibootmgr` checks that Windows/Void entries survived

## How to add a new TUI screen

1. Create `tui/new_screen.sh` with a `screen_new_screen()` function
2. Add `source "${TUI_DIR}/new_screen.sh"` in `install.sh`
3. Add `screen_new_screen` to `register_wizard_screens` in `run_configuration_wizard()`
4. The screen must return `TUI_NEXT`/`TUI_BACK`/`TUI_ABORT`

## How to add a new configuration variable

1. Add the name to `CONFIG_VARS[]` in `lib/constants.sh`
2. Set the value in the appropriate TUI screen + `export`
3. Use it in the appropriate `lib/` module

## How to add a new installation phase

1. Add the checkpoint name to `CHECKPOINTS[]` in `lib/constants.sh`
2. Add logic in `_do_chroot_phases()` (chroot) or the outer process phase dispatcher in `install.sh`
3. Add an entry to `INSTALL_PHASES[]` in `tui/progress.sh`
4. Wrap the block with `if ! checkpoint_reached "name"; then ... checkpoint_set "name"; fi`
