# nfcPlayer (Go version)

A Go port of the Python `nfc_player.py` in the parent directory. Same behaviour,
same Google Sheet, same reader — but it compiles to a **single static binary**
with no cgo, so you can cross-compile it on any machine and drop just the binary
on the Pi (no Python, no `pyscard`, no Go toolchain on the Pi).

It uses the pure-Go PC/SC client [`gballet/go-libpcsclite`](https://github.com/gballet/go-libpcsclite),
which talks to the `pcscd` daemon over its socket directly. That daemon still
does the USB/ACR122U work, so `pcscd` must be installed and running on the Pi
(the installer handles it).

## Cross-compile (on your dev machine — macOS/Linux/x86/arm, any of them)

```bash
cd nfcPlayer/go
bash build.sh
```

This writes static binaries to `dist/`:

- `dist/nfcplayer-linux-arm64` — 64-bit Raspberry Pi OS (Pi 3/4/5, most current installs)
- `dist/nfcplayer-linux-armv7` — 32-bit Raspberry Pi OS

Both are `CGO_ENABLED=0` static ELF binaries — no shared libraries needed. To
build just one by hand:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o nfcplayer .
```

## Install (on the Pi)

Copy this `go/` directory (including `dist/`) to the Pi, then:

```bash
bash install.sh
```

The installer picks the binary matching the Pi's architecture, installs `pcscd`
/ the ACR122U driver / `mpv`, blacklists the conflicting kernel NFC modules,
routes audio to the headphone jack, drops the binary in `~/nfc-player-go/`, and
installs a systemd user service (`nfc-player-go`). No Go or dev headers required.

If you just want the binary: `scp dist/nfcplayer-linux-arm64` to the Pi, make
sure `pcscd` and `mpv` are installed, and run it.

## Run

```bash
./nfcplayer             # run the player
./nfcplayer --register  # print tag UIDs for filling in the sheet
```

## Implementation note

The pure-Go PC/SC client has no blocking "card inserted" event (unlike
`pyscard`/`ebfe/scard`), so the reader is polled every 250 ms: it tries to
connect to each reader, and a successful connect means a tag is present. A UID
is emitted once per insertion — a tag left on the reader isn't re-read until
it's lifted and tapped again. Behaviour is otherwise identical to the Python
version.

## Troubleshooting

**`SCardEstablishContext: Access denied` / the service crash-loops at boot.**
Modern `pcsc-lite` gates `pcscd` behind polkit, which by default only allows an
*active desktop session*. A boot/background service (and an SSH shell) is
inactive, so it's denied. `install.sh` installs a polkit rule
(`/etc/polkit-1/rules.d/49-pcscd.rules`) that grants PC/SC access regardless of
session state — that's what makes the on-boot service work. If you installed the
binary by hand, add that rule yourself and `sudo systemctl restart polkit pcscd`.

## Configuration

Same environment variables as the Python version (set them in
`~/.config/systemd/user/nfc-player-go.service`):

| Variable | Default | Meaning |
|---|---|---|
| `SHEET_ID` | (this project's sheet) | Google Sheet document ID |
| `SHEET_REFRESH_SECONDS` | `300` | How often to re-fetch the sheet |
| `SAME_TAG_STOPS` | `1` | `1` = same tag stops playback, `0` = restarts it |
| `AUDIO_DEVICE` | (system default) | mpv audio device, e.g. `alsa/plughw:CARD=Headphones` |
| `PLAYER_CMD` | `mpv --no-video --really-quiet` | Player command |

See the parent `README.md` for hardware notes, tag registration, and
troubleshooting — they apply unchanged.
```
