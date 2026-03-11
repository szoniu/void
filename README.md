# Void Linux TUI Installer

Interaktywny installer Void Linux z interfejsem TUI (gum/dialog). Przeprowadza za rękę przez cały proces instalacji — od partycjonowania dysku po działający desktop KDE Plasma. Po awarii: `./install.sh --resume` skanuje dyski i wznawia od ostatniego checkpointu.

## Krok po kroku (od zera do działającego systemu)

### 1. Przygotuj bootowalny pendrive

Pobierz Void Linux Live ISO (wariant `base` lub `xfce`):

- https://voidlinux.org/download/ → **x86_64** → **Live ISO** (base lub xfce)

Nagraj na pendrive (Linux/macOS):

```bash
# UWAGA: /dev/sdX to twój pendrive, nie dysk systemowy!
sudo dd if=void-live-x86_64-*.iso of=/dev/sdX bs=4M status=progress
sync
```

Na Windows użyj [Rufus](https://rufus.ie) lub [balenaEtcher](https://etcher.balena.io).

### 2. Bootuj z pendrive

- Wejdź do BIOS/UEFI (zwykle F2, F12, Del przy starcie)
- **Wyłącz Secure Boot** (NVIDIA drivers tego wymagają)
- Ustaw boot z USB
- Wybierz opcję **UEFI** (nie Legacy/CSM!)

Void Live ISO loguje automatycznie jako `root` (hasło: `voidlinux`).

### 3. Połącz się z internetem

#### Kabel LAN (ethernet)

Powinno działać od razu. Sprawdź:

```bash
ping -c 3 voidlinux.org
```

#### WiFi (bezprzewodowo)

**Opcja A: `wpa_supplicant`** — dostępny na Void Live ISO:

```bash
# Znajdź interfejs WiFi
ip link show

# Włącz interfejs
ip link set wlan0 up

# Połącz
wpa_supplicant -B -i wlan0 -c <(wpa_passphrase "NazwaTwojejSieci" "TwojeHaslo")
dhcpcd wlan0
```

**Opcja B: `nmcli` (NetworkManager)** — na xfce live:

```bash
nmcli device wifi list
nmcli device wifi connect 'NazwaTwojejSieci' password 'TwojeHaslo'
```

**Sprawdź połączenie:**

```bash
ping -c 3 voidlinux.org
```

### 4. Sklonuj repo i uruchom installer

```bash
xbps-install -Sy git
git clone https://github.com/szoniu/void.git
cd void
./install.sh
```

> **Błąd SSL przy `git clone`?** Zegar systemowy może być przestarzały. Ustaw datę: `date -s "2026-03-05 12:00:00"` (wstaw aktualną).
>
> **`Permission denied (publickey)`?** Użyj adresu HTTPS (jak wyżej), nie SSH (`git@github.com:...`). Live ISO nie ma Twoich kluczy SSH.

Installer poprowadzi Cię przez 15 ekranów konfiguracji, a potem zainstaluje wszystko automatycznie.

### 5. Po instalacji

Po zakończeniu installer zapyta czy chcesz rebootować. Wyjmij pendrive i uruchom komputer — powinieneś zobaczyć GRUB, a potem ekran logowania SDDM z KDE Plasma.

## Alternatywne sposoby uruchomienia

```bash
# Tylko konfiguracja (generuje plik .conf, nic nie instaluje)
./install.sh --configure

# Instalacja z gotowego configa (bez wizarda)
./install.sh --config moj-config.conf --install

# Wznów po awarii (skanuje dyski w poszukiwaniu checkpointów)
./install.sh --resume

# Dry-run — przechodzi cały flow BEZ dotykania dysków
./install.sh --dry-run
```

## Wymagania

- Komputer z **UEFI** (nie Legacy BIOS)
- **Secure Boot wyłączony**
- Minimum **10 GiB** wolnego miejsca na dysku docelowym
- Połączenie z internetem (LAN lub WiFi)
- Bootowalny pendrive z Void Live ISO (lub dowolne live z `bash` i `git`)

## Co robi installer

15 ekranów TUI prowadzi przez:

| # | Ekran | Co konfigurujesz |
|---|-------|-------------------|
| 1 | Welcome | Sprawdzenie wymagań (root, UEFI, sieć) |
| 2 | Preset | Opcjonalne załadowanie gotowej konfiguracji |
| 3 | Hardware | Podgląd wykrytego CPU, GPU, dysków, peryferiali, zainstalowanych OS-ów |
| 4 | Dysk | Wybór dysku + schemat (auto/dual-boot/manual) + shrink wizard |
| 5 | Filesystem | ext4 / btrfs (ze subvolumes) / XFS |
| 6 | Swap | zram (domyślnie) / partycja / plik / brak |
| 7 | Sieć | Hostname + mirror Void |
| 8 | Locale | Timezone, język, keymap |
| 9 | Kernel | mainline (rolling) lub LTS (stabilny) |
| 10 | GPU | Auto-wykryty sterownik + hybrid GPU (PRIME offload) + NVIDIA open |
| 11 | Desktop | KDE Plasma + wybór aplikacji (Firefox, Thunderbird, Kate...) |
| 12 | Użytkownicy | Hasło root, konto użytkownika, grupy |
| 13 | Pakiety | Dodatkowe pakiety + wykryte peryferiale (Bluetooth, fingerprint, Thunderbolt, IIO sensors, webcam, WWAN) + ASUS ROG/TUF tools (asusctl) |
| 14 | Preset save | Opcjonalny eksport konfiguracji na przyszłość |
| 15 | Podsumowanie | Pełny przegląd + potwierdzenie "YES" + countdown |

### Wykrywanie hardware

Installer automatycznie wykrywa i konfiguruje:

- **GPU** — NVIDIA, AMD, Intel. W laptopach z dwoma kartami (np. Intel iGPU + NVIDIA dGPU) wykrywa **hybrid GPU** i konfiguruje PRIME render offload. Obsługuje NVIDIA open kernel module (Turing+).
- **ASUS ROG/TUF** — wykrywanie przez DMI sysfs. Gdy wykryty, oferuje instalację `asusctl` (sterowanie wentylatorami, RGB, profile wydajności) z serwisem `asusd`.
- **Peryferiale** — 6 automatycznych detekcji: Bluetooth, czytnik linii papilarnych (fprintd), Thunderbolt (bolt), czujniki IIO (iio-sensor-proxy), kamera, WWAN/LTE (ModemManager). Wykryte urządzenia pojawiają się jako opcje w ekranie pakietów.

## Dual-boot (Windows, Linux, multi-boot)

Installer automatycznie:
- Wykrywa zainstalowane OS-y (Windows, Ubuntu, Fedora, openSUSE, Arch, etc.)
- Wykrywa istniejący ESP z Windows Boot Manager i innymi bootloaderami
- Reuse'uje ESP (nigdy go nie formatuje!)
- GRUB instaluje się do `EFI/void/` obok `EFI/Microsoft/` i innych
- `os-prober` dodaje wszystkie wykryte OS-y do menu GRUB
- Partycje z istniejącymi OS-ami są oznaczone w menu — przypadkowe nadpisanie wymaga potwierdzenia `ERASE`
- Po instalacji weryfikuje czy GRUB i wpisy EFI zawierają wszystkie OS-y

Gdy brakuje miejsca na dysku, installer oferuje **shrink wizard** — zmniejszenie istniejącej partycji (NTFS/ext4/btrfs) z marginesem bezpieczeństwa 1 GiB.

## Presety (konfiguracja wielokrotnego użytku)

Przykładowy preset w `presets/example.conf`.

Presety są **przenośne między maszynami** — wartości sprzętowe (CPU, GPU, dysk, peryferiale) są automatycznie re-wykrywane przy imporcie. Konfigurujesz raz, instalujesz na wielu komputerach.

Możesz wyeksportować własny preset w ekranie 14 wizarda.

## Co jeśli coś pójdzie nie tak

### Recovery menu

Gdy komenda się nie powiedzie, installer wyświetli menu recovery:

- **(r)etry** — ponów komendę (np. po naprawieniu problemu w shellu)
- **(s)hell** — wejdź do shella, napraw ręcznie, wpisz `exit` żeby wrócić
- **(c)ontinue** — pomiń ten krok i kontynuuj (ostrożnie!)
- **(l)og** — pokaż log błędu
- **(a)bort** — przerwij instalację

### Wznowienie po awarii (`--resume`)

Jeśli instalacja została przerwana (OOM kill, zawieszenie, utrata SSH, przerwa w prądzie), możesz wznowić jedną komendą:

```bash
./install.sh --resume
```

`--resume` automatycznie:
1. Skanuje wszystkie partycje (ext4/btrfs/xfs) w poszukiwaniu danych z poprzedniej instalacji
2. Odzyskuje checkpointy (informacje o ukończonych fazach) i plik konfiguracji
3. Jeśli config nie przetrwał — próbuje go **odtworzyć z zainstalowanego systemu** (fstab, xbps.d, rc.conf, hostname, locale...)
4. Pomija już ukończone fazy i kontynuuje od miejsca przerwania

Co przetrwało na dysku docelowym:
- **Checkpointy** — pliki w `/tmp/void-installer-checkpoints/` na partycji docelowej
- **Config** — `/tmp/void-installer.conf` na partycji docelowej (zapisywany po fazie partycjonowania)

Ręczna alternatywa (jeśli `--resume` nie zadziała):

```bash
# 1. Zamontuj dysk docelowy
mount /dev/sdX2 /mnt/void

# 2. Skopiuj checkpointy
cp -a /mnt/void/tmp/void-installer-checkpoints/* /tmp/void-installer-checkpoints/

# 3. Skopiuj config (jeśli istnieje)
cp /mnt/void/tmp/void-installer.conf /tmp/void-installer.conf

# 4. Odmontuj i uruchom normalnie
umount /mnt/void
./install.sh
```

### Drugie TTY — twój najlepszy przyjaciel

Podczas instalacji masz dostęp do wielu konsol. Przełączaj się przez **Ctrl+Alt+F1**...**F6**:

- **TTY1** — installer
- **TTY2-6** — wolne konsole do debugowania

Na drugim TTY możesz:

```bash
# Podgląd co się dzieje
top

# Log installera
tail -f /tmp/void-installer.log                  # przed chroot
tail -f /mnt/void/tmp/void-installer.log         # w chroot

# Sprawdź czy coś nie zawiesiło się
ps aux | grep -E "tee|xbps"
```

### Zdalna instalacja przez SSH

Na maszynie docelowej (bootowanej z Live ISO):

```bash
# 1. Ustaw hasło root
passwd root

# 2. Zainstaluj i uruchom sshd
xbps-install -Sy openssh
ln -sf /etc/sv/sshd /var/service/sshd

# 3. Sprawdź IP
ip -4 addr show | grep inet
```

Z innego komputera:

```bash
ssh -o PubkeyAuthentication=no root@<IP-live-ISO>
xbps-install -Sy git
git clone https://github.com/szoniu/void.git
cd void
./install.sh
```

#### Monitorowanie z drugiego połączenia

```bash
ssh root@<IP-live-ISO>

# Logi w czasie rzeczywistym
tail -f /tmp/void-installer.log                  # przed chroot
tail -f /mnt/void/tmp/void-installer.log         # w chroot

# Co się instaluje
top
```

### Typowe problemy

#### Przed instalacją

- **`git clone` — SSL certificate not yet valid** — zegar systemowy jest przestarzały. Ustaw datę: `date -s "2026-03-05 12:00:00"` (wstaw aktualną).
- **`git clone` — Permission denied (publickey)** — użyj HTTPS: `git clone https://github.com/szoniu/void.git`, nie SSH (`git@github.com:...`).
- **Preflight: "Network connectivity required"** — installer pinguje `voidlinux.org` i `google.com`. Jeśli sieć działa ale DNS nie, dodaj ręcznie: `echo "nameserver 8.8.8.8" >> /etc/resolv.conf`. Installer próbuje to naprawić automatycznie (`ensure_dns`).

#### W trakcie instalacji

- **xbps-install — "Name or service not known"** — DNS przestał działać. Na innym TTY (`Ctrl+Alt+F2`) wpisz: `echo "nameserver 8.8.8.8" >> /etc/resolv.conf`, wróć na TTY1 i wybierz `r` (retry).
- **Installer zawisł, nic się nie dzieje** — sprawdź na TTY2 (`Ctrl+Alt+F2`) czy `xbps-install` działa w `top`. Jeśli tak — pobieranie/instalacja trwa, po prostu czekaj.
- **Przerwa w prądzie / reboot** — uruchom `./install.sh --resume`, automatycznie wznowi od ostatniego checkpointu.
- **Menu "retry / shell / continue / abort"** — installer napotkał błąd. `r` = spróbuj ponownie, `s` = otwórz shell i napraw ręcznie (potem `exit`), `c` = pomiń ten krok, `a` = przerwij instalację.

#### Ogólne

- **Log** — pełny log instalacji: `/tmp/void-installer.log` (przed chroot) i `/mnt/void/tmp/void-installer.log` (w chroot)
- **Coś jest nie tak z konfiguracją** — użyj `./install.sh --configure` żeby przejść wizarda ponownie

## Interfejs TUI

Installer ma trzy backendy TUI (w kolejności priorytetu):

1. **gum** (domyślny) — nowoczesny, zaszyty w repo jako `data/gum.tar.gz` (~4.5 MB). Ekstrahowany automatycznie do `/tmp` na starcie. Zero dodatkowych zależności.
2. **dialog** — klasyczny TUI, dostępny na większości live ISO
3. **whiptail** — fallback gdy brak `dialog`

Backend jest wybierany automatycznie. Żeby wymusić fallback na `dialog`/`whiptail`:

```bash
GUM_BACKEND=0 ./install.sh
```

### Aktualizacja gum

Żeby zaktualizować bundlowaną wersję gum:

```bash
# 1. Pobierz nowy tarball (podmień wersję)
curl -fSL -o data/gum.tar.gz \
  "https://github.com/charmbracelet/gum/releases/download/v0.18.0/gum_0.18.0_Linux_x86_64.tar.gz"

# 2. Zaktualizuj GUM_VERSION w lib/constants.sh (musi pasować)
#    : "${GUM_VERSION:=0.18.0}"
```

## Hooki (zaawansowane)

Własne skrypty uruchamiane przed/po fazach instalacji:

```bash
cp hooks/before_install.sh.example hooks/before_install.sh
chmod +x hooks/before_install.sh
# Edytuj hook...
```

Dostępne hooki: `before_install`, `after_install`, `before_preflight`, `after_preflight`, `before_disks`, `after_disks`, `before_rootfs`, `after_rootfs`, `before_xbps_preconfig`, `after_xbps_preconfig`, `before_xbps_update`, `after_xbps_update`, `before_system_config`, `after_system_config`, `before_kernel`, `after_kernel`, `before_fstab`, `after_fstab`, `before_networking`, `after_networking`, `before_bootloader`, `after_bootloader`, `before_swap`, `after_swap`, `before_desktop`, `after_desktop`, `before_users`, `after_users`, `before_extras`, `after_extras`, `before_finalize`, `after_finalize`.

## Opcje CLI

```
./install.sh [OPCJE] [POLECENIE]

Polecenia:
  (domyślnie)      Pełna instalacja (wizard + install)
  --configure       Tylko wizard konfiguracyjny
  --install         Tylko instalacja (wymaga configa)
  --resume          Wznów po awarii (skanuje dyski)

Opcje:
  --config PLIK     Użyj podanego pliku konfiguracji
  --dry-run         Symulacja bez destrukcyjnych operacji
  --force           Kontynuuj mimo nieudanych prereq
  --non-interactive Przerwij na każdym błędzie (bez recovery menu)
  --help            Pokaż pomoc

Zmienne środowiskowe:
  GUM_BACKEND=0     Wymuś fallback na dialog/whiptail (pomiń gum)
```

## Uruchamianie testów

```bash
bash tests/test_config.sh        # Config round-trip
bash tests/test_hardware.sh      # GPU database
bash tests/test_disk.sh          # Disk planning dry-run z sfdisk
bash tests/test_checkpoint.sh    # Checkpoint validate + migrate
bash tests/test_resume.sh        # Resume from disk scanning + recovery
bash tests/test_multiboot.sh     # Multi-boot OS detection + serialization
bash tests/test_infer_config.sh  # Config inference from installed system
```

Wszystkie testy są standalone — nie wymagają root ani hardware. Używają `DRY_RUN=1` i `NON_INTERACTIVE=1`.

## Struktura projektu

```
install.sh              — Główny entry point
configure.sh            — Wrapper: tylko wizard TUI

lib/                    — Moduły biblioteczne (sourcowane, nie uruchamiane)
tui/                    — Ekrany TUI (każdy = funkcja, return 0/1/2)
data/                   — GPU database, mirrors, motyw TUI, bundled gum binary
presets/                — Gotowe presety
hooks/                  — Hooki (*.sh.example)
tests/                  — Testy
TODO.md                 — Planowane ulepszenia
```

## FAQ

**P: Jak długo trwa instalacja?**
Void instaluje pakiety binarne (XBPS), więc 15-30 minut w zależności od łącza. Nie kompiluje niczego ze źródeł.

**P: Mogę zainstalować na VM?**
Tak, ale upewnij się że VM jest w trybie UEFI. W VirtualBox: Settings → System → Enable EFI. W QEMU: dodaj `-bios /usr/share/ovmf/OVMF.fd`.

**P: Co jeśli mam Secure Boot?**
Wyłącz Secure Boot w BIOS. NVIDIA proprietary drivers nie są podpisane.

**P: Mogę użyć innego live ISO niż Void?**
Tak, dowolne live ISO z Linuxem zadziała, pod warunkiem że ma `bash`, `git`, `sfdisk`, `wget`, `tar`, `sha256sum`, `chroot`. Installer ma zaszyty `gum` jako backend TUI, więc `dialog`/`whiptail` nie jest wymagany.

**P: Co jeśli `gum` nie działa?**
Installer automatycznie użyje `dialog` lub `whiptail` jako fallback. Możesz też wymusić fallback: `GUM_BACKEND=0 ./install.sh`.

**P: Dlaczego runit, a nie systemd?**
Void Linux używa runit jako domyślnego systemu init. Installer jest w pełni dostosowany do runit (serwisy przez symlinki w `/var/service/`, elogind zamiast systemd-logind, zramen zamiast zram-generator).

**P: Co to jest base-voidstrap → base-system?**
ROOTFS tarball zawiera minimalny pakiet `base-voidstrap`. Installer automatycznie zamienia go na pełny `base-system` podczas pierwszej aktualizacji XBPS. To standardowa procedura Void Linux.

**P: Mam multi-boot (kilka Linuxów). Po aktualizacji kernela inne systemy zniknęły z GRUB.**
Ostatni zainstalowany GRUB jest master bootloaderem. Po aktualizacji kernela w dowolnym systemie trzeba odświeżyć GRUB:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Wystarczy uruchomić z dowolnego systemu, który ma GRUB + os-prober. Jeśli używasz `~/dotfiles` aktualizatora, robi to automatycznie.

**P: Zapomniałem odświeżyć GRUB i po restarcie nie widzę innych systemów.**
Systemy dalej są na dysku — nic nie zostało usunięte. Wystarczy:

1. Uruchom dowolny z widocznych systemów
2. Upewnij się że `os-prober` jest zainstalowany (`xbps-install -S os-prober`)
3. Uruchom `sudo grub-mkconfig -o /boot/grub/grub.cfg`
4. Restart — wszystkie systemy powinny być widoczne

Jeśli żaden system nie startuje (uszkodzony GRUB), boot z Live USB i napraw z chroot:

```bash
mount /dev/<root-partycja> /mnt
mount /dev/<esp> /mnt/boot/efi
mount --rbind /dev /mnt/dev && mount --rbind /sys /mnt/sys && mount -t proc /proc /mnt/proc
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
```
