# camlight

<img src="Assets/AppIcon.png" alt="camlight light-bulb icon" width="160">

camlight is a native macOS menu-bar app that switches a USB-powered light when a
camera starts or stops streaming. It can control several lights, associate each
one with a particular camera, and toggle all configured ports with a global
keyboard shortcut.

## Features

- Detects camera use without requesting camera access
- Controls power on compatible USB hub ports
- Shows the attached device beside every discovered port
- Groups ports by hub and supports persistent hub names
- Supports configurable on/off delays
- Provides manual menu-bar and global-hotkey toggles
- Runs at login when enabled in Settings
- Bundles its USB control helper; no `uhubctl` installation is required

## Requirements

- macOS 13 or later
- A USB hub that implements per-port power switching (`ppps`)

Not every hub that advertises port switching actually cuts VBUS power. Test your
hardware before relying on it.

## Build

The repository includes the pinned `uhubctl` and `libusb` source needed by the
app. The only build requirement is Apple's Command Line Tools:

```sh
xcode-select --install
make
```

The resulting `camlight.app` is self-contained. Copy it to `/Applications` and
open it. macOS may ask you to approve the app because local builds are ad-hoc
signed.

Run the parser and settings migration tests with:

```sh
make test
```

## Usage

1. Open Settings from the menu-bar light bulb.
2. Add a light and choose its camera and USB port.
3. Optionally rename the selected port's hub.
4. Click the Toggle hotkey control and type a modified key combination. Press
   Delete while recording to disable the shortcut.

Left-clicking the menu-bar icon or pressing the hotkey toggles all configured
lights. Right-clicking opens the app menu.

## License

camlight is licensed under GPL-2.0-only. It incorporates code from `uhubctl`,
which uses the same license, and `libusb`, which is LGPL-2.1-or-later. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for pinned versions and
attribution.
