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
