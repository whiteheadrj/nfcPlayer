# nfcPlayer

Tap an NFC-tagged book on the reader and the Raspberry Pi plays that book's
audio through the 3.5mm headphone jack.

**Hardware:** Raspberry Pi 4 (1GB is plenty) running Raspberry Pi OS, with an
ACS ACR122U USB NFC reader and NTAG213 stickers on the books.

**How it works:** the app watches the ACR122U for tag taps, reads the tag's
UID, looks it up in the [Google Sheet](https://docs.google.com/spreadsheets/d/1EW7mGv9IMcwiIqwEJGDhc8e-PXXOceAWLizcIYIbi-U/edit)
(columns `Tag`, `Book Title`, `Link`), and streams the row's audio URL with
`mpv`. Tapping a different book switches to it; tapping the same book while
it's playing stops it.

## Install (on the Pi)

```bash
git clone <this repo> nfcPlayer && cd nfcPlayer
bash install.sh
```

The installer:

- installs `pcscd`, the ACR122U driver (`libacsccid1`), `python3-pyscard`, and `mpv`
- blacklists the kernel's built-in NFC modules (they fight with the ACR122U driver)
- switches audio output to the headphone jack
- installs and starts a systemd user service (`nfc-player`) that runs on boot

Plug the ACR122U into any USB port. Its LED turns green when `pcscd` has
claimed it; it beeps when it sees a tag.

## Register your books

1. Stop the player and run register mode:

   ```bash
   systemctl --user stop nfc-player
   python3 ~/nfc-player/nfc_player.py --register
   ```

2. Tap each book's tag — its UID prints (e.g. `04A2BB12C45E80`).
3. Put that UID in the sheet's `Tag` column, the book name in `Book Title`,
   and the audio file URL in `Link`.
4. Restart: `systemctl --user start nfc-player`

You can also skip register mode entirely: tap an unknown tag while the player
is running and its UID appears in the logs
(`journalctl --user -u nfc-player -f`).

### Link column notes

- Direct URLs to `.mp3`/`.m4a`/etc. work best.
- Google Drive share links (`drive.google.com/file/d/...`) and Dropbox share
  links are converted to direct-download form automatically. Drive files must
  be shared as "Anyone with the link", and very large Drive files (>100MB) may
  be blocked by Drive's virus-scan page — a direct host is more reliable.
- The sheet itself must be viewable by "Anyone with the link" (it already is).

## Everyday use

- **Tap a book** → its audio plays from the beginning.
- **Tap a different book** → playback switches immediately.
- **Tap the same book while playing** → playback stops.
- New rows added to the sheet are picked up within 5 minutes — or instantly,
  since an unknown tag triggers an immediate re-fetch of the sheet.

## Configuration

Set environment variables in `~/.config/systemd/user/nfc-player.service`
(then `systemctl --user daemon-reload && systemctl --user restart nfc-player`):

| Variable | Default | Meaning |
|---|---|---|
| `SHEET_ID` | (this project's sheet) | Google Sheet document ID |
| `SHEET_REFRESH_SECONDS` | `300` | How often to re-fetch the sheet |
| `SAME_TAG_STOPS` | `1` | `1` = same tag stops playback, `0` = restarts it |
| `AUDIO_DEVICE` | (system default) | mpv audio device, e.g. `alsa/plughw:CARD=Headphones` |

## Troubleshooting

- **Reader not detected** — `pcsc_scan` should show the ACR122U and react to
  tags. If it doesn't, reboot once (so the module blacklist takes effect) and
  check `systemctl status pcscd`.
- **No sound / wrong output** — run `sudo raspi-config` → System Options →
  Audio → Headphones. Test with `mpv <some-audio-url>`.
- **Tag reads but nothing plays** — watch the logs
  (`journalctl --user -u nfc-player -f`): an unknown UID means the sheet row
  doesn't match (the UID must match exactly, no spaces); a player error means
  the URL isn't a streamable audio file.
