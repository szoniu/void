# TODO — Void Linux TUI Installer

## Port from Gentoo

- [ ] Secure Boot support (shim + MOK) — `lib/secureboot.sh` + `tui/secureboot_config.sh`
- [ ] Desktop type selection (Plasma vs none/server) — `tui/desktop_select.sh`
- [ ] test_hybrid_gpu.sh — port from gentoo `tests/test_hybrid_gpu.sh`
- [ ] test_validate.sh — port from gentoo `tests/test_validate.sh`
- [ ] test_peripherals.sh — port from gentoo `tests/test_peripherals.sh`
- [ ] test_shrink.sh — port from gentoo `tests/test_shrink.sh`

## Planned Features

- [ ] Musl libc support (alternative ROOTFS)
- [ ] Custom package set presets (minimal, developer, gaming)
- [ ] Btrfs snapshot integration with snapper
- [ ] Full disk encryption (LUKS)
- [ ] LVM support
- [ ] Wi-Fi configuration during installation (TUI screen)
- [ ] Accessibility improvements (screen reader support)
- [ ] Localized installer UI (i18n)
- [ ] Alternative desktop environments (GNOME, XFCE, Sway)
- [ ] Flatpak auto-configuration (Flathub remote setup)
- [ ] Wayland-only installation option (no Xorg)

## Done

- [x] Post-install script hooks for automation — `lib/hooks.sh`
- [x] Live preview of disk operations before execution — `disk_plan_show()` in `lib/disk.sh`
- [x] SSH-based remote installation — works natively (TUI over SSH)
- [x] Audit & fix: ESP mount path mismatch (`/efi` → `/boot/efi`)
- [x] Audit & fix: unmount_filesystems awk field `$3` → `$2`
- [x] Audit & fix: peripheral tools (fingerprint/thunderbolt/sensors/wwan/asusctl) now installed + services enabled
- [x] Audit & fix: hybrid GPU iGPU drivers installed alongside dGPU
- [x] Audit & fix: GPU_USE_NVIDIA_OPEN now used for nvidia-open-dkms
- [x] Audit & fix: BTRFS_SUBVOLUMES inference returns actual subvol pairs (not "yes")
- [x] Audit & fix: KERNEL_TYPE="default" → "mainline"
- [x] Audit & fix: pre-chroot hooks wired into `_execute_phase()`
- [x] Audit & fix: vscode case warns instead of failing
- [x] Audit & fix: swap file swapon + secure permissions
- [x] Audit & fix: SWAP_TYPE validation (file requires size, partition doesn't)
- [x] Audit & fix: ENABLE_* flags properly reset in extra_packages checklist
- [x] Audit & fix: preset_compare() unquotes values before comparison
- [x] Audit & fix: removed Gentoo leftovers (dialogrc, GRUB_PLATFORMS, test comments)
- [x] Audit & fix: dead code removed (run_pre_chroot, _strip_ansi, linux-mainline check)
- [x] Audit & fix: --config guard, stty echo restore, GPU_DEVICE_ID/NAME in CONFIG_VARS
