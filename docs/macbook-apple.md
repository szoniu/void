# Void na Intel MacBooku (MacBook10,1 i pokrewne)

Sprawdzone pod **MacBook 12" Mid 2017 (MacBook10,1)** — Core i5-7Y54 (Kaby Lake Y),
Intel HD 615, BCM4350 Wi-Fi/BT, NVMe, panel 2304×1440, **jeden port USB-C, zero Ethernetu**.
Dotyczy też MacBook8,1/9,1 i MacBookPro13,*/14,* (ta sama rodzina quirków).

## Co instalator robi automatycznie

`detect_apple()` (`lib/apple.sh`) czyta DMI `sys_vendor` = `Apple Inc.` i ustawia
`APPLE_DETECTED`, `APPLE_MODEL`, `APPLE_SPI_INPUT`. Z tego wynikają cztery zachowania:

| Obszar | Co się dzieje | Gdzie |
|---|---|---|
| Bootloader | GRUB instalowany **dodatkowo** na ścieżkę removable `EFI/BOOT/BOOTX64.EFI` | `lib/bootloader.sh` |
| Klawiatura/touchpad | `applespi` + `spi_pxa2xx_platform` + `intel_lpss_pci` wymuszone do initramfs (dracut) i `modules-load.d` | `lib/apple.sh`, wołane z `kernel_install` |
| Secure Boot | ekran MOK/shim **pomijany** (Intel Mac bez T2 nie ma UEFI Secure Boot) | `tui/secureboot_config.sh` |
| Bluetooth | instalacja `broadcom-bt-firmware` (plik `.hcd`, którego linux-firmware nie zawiera) | faza `apple_quirks` |

Dodatkowo `/etc/modprobe.d/apple-hid.conf` (`fnmode=2` — F1..F12 jako podstawowa
funkcja) i `/root/POST-INSTALL-APPLE.txt` z resztą ustawień.

## Pułapki

### Maki z T2 (2018+) nie są wspierane

`detect_apple()` sprawdza PCI vendor `0x106b`. T2 wymaga out-of-tree `apple-bce`
i kernela t2linux, żeby w ogóle zobaczyć wewnętrzny SSD i klawiaturę — instalator
tego nie ma i mówi to wprost (ostrzeżenie, wpis w podsumowaniu, notatka
post-install). MacBook10,1 **nie ma** T2, więc go to nie dotyczy.

### Apple EFI gubi wpisy NVRAM

`efibootmgr` wpisuje entry, firmware Apple potrafi je zignorować albo skasować przy
kolejnym starcie. Dlatego GRUB ląduje też pod `EFI/BOOT/BOOTX64.EFI` — wtedy Startup
Manager (przytrzymaj **Option/Alt** przy starcie) pokazuje go jako „EFI Boot".
Bez tego objaw jest mylący: instalacja przebiega bez błędu, `efibootmgr` pokazuje wpis,
a Mac i tak wstaje w macOS.

### APFS nie da się zmniejszyć z Linuksa

Żadne narzędzie tego nie potrafi (`apfs-fuse` jest read-only i nie ma go w repo Void).
**Kontener trzeba skurczyć w macOS przed startem instalatora**:

```
diskutil apfs resizeContainer disk1 300g
```

albo Disk Utility → kontener → Partition. Zostaw **wolne miejsce**, nie twórz tam partycji
— zrobi to instalator. Minimum 30 GiB, wcześniej Time Machine.

Instalator wykrywa APFS/HFS+ po **GPT type GUID** (`7c3457ef-…` / `48465300-…`), nie po
`FSTYPE` — libblkid na starszych nośnikach live nie zna APFS. Bez tej detekcji tryb `auto`
nie zapytałby o `ERASE`, bo nie wykryłby żadnego systemu na dysku.

### Klawiatura i touchpad wiszą na SPI, nie na USB

`applespi` jest w mainline (`drivers/input/keyboard/applespi.c`, ACPI ID `APP000D`,
„MacBook8 and newer"), a Void ma `CONFIG_KEYBOARD_APPLESPI=m` w `linux6.12` i `linux6.18`.
Stos jest trzywarstwowy: `intel_lpss_pci` (enumeracja kontrolera) → `spi_pxa2xx_platform`
(sterownik SPI) → `applespi`.

Objaw przy braku modułów w initramfs: brak klawiatury na wczesnym boocie (rescue shell,
prompt LUKS). Jeśli touchpad milczy po zalogowaniu: `rmmod applespi && modprobe applespi`.

**Plan B na czas instalacji:** hub USB-C + klawiatura USB. Warto mieć go pod ręką, bo
jedyny port jest zajęty przez pendrive.

### Wi-Fi to jedyna droga do sieci

Brak Ethernetu → bez Wi-Fi instalator nie pobierze ROOTFS. **Najprościej: nagraj
wariant live `xfce`** (nie `base`) — ma NetworkManagera z apletem w tacce, więc
sieć klikasz przed uruchomieniem instalatora. Firmware sieciowe jest na obu
wariantach (`linux-base` → `linux-firmware-network` → `linux-firmware-broadcom`).

Ekran `tui/wifi_config.sh` pokazuje się automatycznie, gdy `has_network` zwraca fałsz (wpa_supplicant + dhcpcd,
hasło wchodzi do `wpa_passphrase` przez stdin, nigdy w argumencie procesu). Wybrana sieć
jest zapisywana jako profil NetworkManagera (`psk` = wyliczony 64-hex, nie hasło jawnym
tekstem) i przenoszona do zainstalowanego systemu, żeby pierwszy boot był online.

BCM4350: `brcmfmac4350-pcie.bin` jest w `linux-firmware-broadcom` (ciągnięte przez
`linux-firmware` → `linux-firmware-network`). Brakuje pliku NVRAM `.txt` — komunikat
`Direct firmware load for brcm/brcmfmac4350-pcie.txt failed` jest **nieszkodliwy**.
5 GHz bywa kapryśne zależnie od rewizji firmware'u. Przy rozłączeniach: odkomentuj
`roamoff=1` w `/etc/modprobe.d/apple-brcmfmac.conf`. `broadcom-wl` **nie obsługuje** 4350.

### Bluetooth bez `.hcd` nie istnieje

Broadcom nie licencjonuje plików patch dla linux-firmware, więc BCM4350 pokazuje
„brak adaptera". Void pakietuje je osobno: `broadcom-bt-firmware`.

### Panel Retina

2304×1440 na 12" — przy skali 1 wszystko jest mikroskopijne, przy 2 za duże.
GNOME potrzebuje fractional scaling:

```
gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
```

niri dostaje `scale 1.5` na `eDP-1` już w `/etc/skel/.config/niri/config.kdl`,
gdy wykryto sprzęt Apple. Instalator zapisuje też
`/etc/xdg-desktop-portal/niri-portals.conf` (`FileChooser=gtk`) — bez tego niri
(smithay, nie wlroots) po cichu odrzuca FileChooser i okna wyboru pliku
w GTK/Electronach nie pojawiają się wcale.

### Czcionka konsoli

Ta sama gęstość pikseli, która wymusza fractional scaling w GUI, robi z konsoli
tekstowej mrowisko — a to jest dokładnie ten ekran, na którym lądujesz, gdy sesja
graficzna nie wstaje. Instalator proponuje czcionkę na ekranie 9 (Locale), dobraną
po dłuższej krawędzi panelu: 2304×1440 MacBooka 12" trafia w `ter-v20n`. Gdy kernel
nie wystawia danych o panelu, sam fakt wykrycia sprzętu Apple wystarcza do
propozycji `ter-v28n` — każdy Mac wspierany przez instalator ma ekran Retina.

Zmiana po instalacji: `FONT=` w `/etc/rc.conf` (wymaga pakietu `terminus-font`).

### Fanless

i5-7Y54 w MacBooku 12" nie ma wentylatora — throttling pod obciążeniem to norma, nie
usterka. `applesmc` ładuje się do odczytu temperatur.

## LUKS na MacBooku — o czym pamiętać

Szyfrowanie roota działa na tym sprzęcie, ale zależy od jednej rzeczy: **prompt na
hasło leci z initramfs**, zanim wstanie jakikolwiek desktop. Klawiatura MacBooka
wisi na SPI, więc bez `applespi` w initramfs nie masz czym wpisać hasła — i system
staje w miejscu, którego nie da się obejść inaczej niż klawiaturą USB.

Instalator wrzuca `applespi`, `spi_pxa2xx_platform` i `intel_lpss_pci` do
`force_drivers` dracuta niezależnie od LUKS-a, więc jest to załatwione — ale przy
pierwszym starcie po instalacji **miej pod ręką hub USB-C i klawiaturę**. Jeśli
prompt się pojawi, a klawiatura nie odpowiada: podłącz USB, wpisz hasło, a po
zalogowaniu sprawdź `lsinitrd /boot/initramfs-*.img | grep applespi`.

Hasło podajesz **raz** (GRUB) — drugie pytanie z initramfs znika dzięki keyfile'owi,
który leży na zaszyfrowanym roocie.

Druga rzecz, o którą instalator pyta przy szyfrowaniu, to **TRIM na zaszyfrowanym
dysku** (domyślnie wyłączony). Na NVMe w MacBooku 12" ma to realne znaczenie — bez
niego cotygodniowy `fstrim` nie przycina nic poza 200-megabajtowym ESP Apple, a dysk
z czasem zwalnia przy zapisie. Cena: ktoś, kto dostanie w ręce wyłączony komputer,
odczyta z niego, **ile** miejsca jest zajęte i mniej więcej gdzie (same dane zostają
zaszyfrowane). Laptop, który wozisz ze sobą i którego nie oddajesz w obce ręce —
włącz; sprzęt, który może trafić do kogoś innego — zostaw wyłączony.

Po instalacji sprawdzisz to jednym poleceniem:
`dmsetup table cryptroot | grep allow_discards`. Gdyby czegoś brakowało,
instalator zostawia gotowy przepis w `/root/POST-INSTALL-LUKS-TRIM.txt`.

## Kolejność przy dual-boocie z macOS

1. macOS: Time Machine.
2. macOS: zrób miejsce — patrz przepis niżej. **To tutaj decydujesz, ile dostanie
   Void.** Instalator nie pyta o rozmiar partycji: w schemacie dual-boot robi
   `sfdisk --append` bez `size=`, więc nowa partycja bierze **cały** wolny obszar
   dysku (minimum, na które instalator się zgodzi, to 10 GiB).
3. Boot z pendrive'a Void: przytrzymaj **Option**, wybierz „EFI Boot".
4. Instalator: schemat **dual-boot**, reuse istniejącego ESP Apple (zwykle `…p1`, 200 MiB).
5. Po instalacji: jeśli Mac wstaje prosto w macOS — Option przy starcie, albo w macOS
   System Settings → Startup Disk.

**os-prober nie wykryje macOS** (APFS), więc wpisu macOS w menu GRUB nie będzie —
przełączanie systemów odbywa się przez Startup Manager Apple.

### Robienie miejsca w macOS — przepis

Cel jest jeden: `diskutil list` ma na końcu pokazywać wiersz **`(free space)`**.
Nie wolumin, nie partycję — **niezagospodarowany obszar GPT**. Instalator tworzy
swoją partycję przez `sfdisk --append`, czyli właśnie w takim obszarze; wolumin
APFS/HFS+ założony „na zapas" liczy się jako zajęte miejsce, a zmniejszyć APFS-a
z Linuksa **nie da się w ogóle** — zostaje powrót do macOS i poprawianie.

To jest też pułapka GUI: w Disk Utility przycisk „+" dodaje **wolumin**, nie wolną
przestrzeń. Stąd terminal.

**1. Zobacz układ dysku** — szukasz `Container diskN` i jego Physical Store
(zwykle `disk0s2`, sam kontener to `disk1`):

```
diskutil list
```

**2. Sprawdź granice, ZANIM spróbujesz zmniejszać:**

```
diskutil apfs resizeContainer disk1 limits
```

Wypisuje minimalny i maksymalny rozmiar kontenera. Minimum wyraźnie wyższe od
zajętych danych (np. 300 GB przy 80 GB plików) oznacza prawie na pewno lokalne
snapshoty — patrz krok 4.

**3. Zmniejsz kontener. Argument to NOWY rozmiar kontenera, czyli ile zostaje
dla macOS** — reszta dysku staje się wolną przestrzenią:

```
diskutil apfs resizeContainer disk1 120g
```

**Nie dopisuj nic po rozmiarze.** Dalsze argumenty (`jhfs+`, nazwa, rozmiar) każą
diskutilowi założyć w odzyskanym miejscu wolumin — czyli dokładnie to, czego ma
tam nie być.

**4. Gdy resize odmawia albo `limits` pokazuje absurdalne minimum** — lokalne
snapshoty APFS. Time Machine robi je także bez podłączonego dysku zewnętrznego
i trzymają bloki, których kontener nie może oddać:

```
tmutil listlocalsnapshots /
```

```
sudo tmutil thinlocalsnapshots / 999999999999 4
```

Potem wróć do kroku 2 — minimum powinno spaść.

**5. Zweryfikuj przed rebootem:**

```
diskutil list
```

Ma być `(free space)` o oczekiwanym rozmiarze. FileVault nie przeszkadza —
zmniejszanie działa przy włączonym.

## Po instalacji: dotfiles

`~/dotfiles` dokłada resztę i nie trzeba tego dublować w instalatorze:

```
bash wizard.sh --install-all
```

- `_setup_repos_void` — nonfree/multilib
- `_setup_niri_ecosystem` — Waybar (uwaga: **wielka W** w Void), fuzzel, mako, swaylock,
  swayidle, xwayland-satellite, matugen…
- aktualizacje: `xbps-install -Syu` (menu tools) albo topgrade

Nie dodawaj martwych repo third-party do `/etc/xbps.d/` — XBPS jest all-or-nothing i przy
podbiciu soname osierocony pakiet blokuje aktualizację **całego** systemu
(szczegóły: `~/dotfiles/docs/void-hyprland-repo.md`).
