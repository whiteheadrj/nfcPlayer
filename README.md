# nfcPlayer

Tap an NFC-tagged book on the reader and the Raspberry Pi plays that book's
audio through the DAC HAT's headphone jack.

**Hardware:** Raspberry Pi 4 (1GB is plenty) running Raspberry Pi OS, an
[InnoMaker HiFi DAC HAT](https://www.amazon.com/dp/B07D13QWV9) (PCM5122) for
audio out, an ACS ACR122U USB NFC reader, and NTAG213 stickers on the books.

**How it works:** the app watches the ACR122U for tag taps, reads the tag's
UID, looks it up in the [Google Sheet](https://docs.google.com/spreadsheets/d/1EW7mGv9IMcwiIqwEJGDhc8e-PXXOceAWLizcIYIbi-U/edit)
(columns `Tag`, `Book Title`, `Link`), and streams the row's audio URL with
`mpv`. Tapping a different book switches to it; tapping the same book while
it's playing stops it.

The first play of a book streams it and downloads a copy in the background;
after that it plays from the local cache — instant start, no re-downloading,
and it keeps working if the network is down. The cache is capped (1 GB by
default) and the least-recently-played books are evicted when it fills.

## Install (on the Pi)

```bash
git clone <this repo> nfcPlayer && cd nfcPlayer
bash install.sh
```

The installer:

- installs `pcscd`, the ACR122U driver (`libacsccid1`), `python3-pyscard`, and `mpv`
- blacklists the kernel's built-in NFC modules (they fight with the ACR122U driver)
- enables the DAC HAT (`dtoverlay=allo-boss-dac-pcm512x-audio`, onboard audio
  off) and makes it the default output — the HAT needs one reboot to appear,
  so re-run `install.sh` after rebooting to finish that step
- installs and starts a systemd user service (`nfc-player`) that runs on boot

Plug the ACR122U into any USB port. Its LED turns green when `pcscd` has
claimed it; it beeps when it sees a tag.

### Updating

The service runs an installed **copy** at `~/nfc-player/`, not the repo
checkout — a `git pull` alone doesn't change what's running. To deploy an
update:

```bash
cd ~/nfcPlayer && git pull
cp nfc_player.py ~/nfc-player/
systemctl --user restart nfc-player
```

(Or re-run `bash install.sh`, which does the same plus the system setup.)

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
  be shared as "Anyone with the link". Very large Drive files (>100MB) hit
  Drive's virus-scan page, which can break the first streamed play — but the
  background cache download follows the confirm form, so from the second tap
  on they play fine from the local copy.
- If you re-record a book, upload it as a **new** file and update the link —
  the changed URL busts the cache. Replacing the contents behind the same
  link keeps playing the old cached copy.
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
| `CACHE_DIR` | `~/.cache/nfc-player` | Where downloaded audio files are kept |
| `CACHE_MAX_MB` | `1024` | Cache size cap in MB; oldest-played files are evicted. `0` disables caching |

## Troubleshooting

- **Reader not detected** — `pcsc_scan` should show the ACR122U and react to
  tags. If it doesn't, reboot once (so the module blacklist takes effect) and
  check `systemctl status pcscd`.
- **`Access denied` / service crash-loops on boot** (Debian trixie and newer) —
  modern `pcsc-lite` gates the daemon behind polkit, which only allows an active
  desktop session; a boot service is inactive and gets denied. The installer
  adds a polkit rule (`/etc/polkit-1/rules.d/49-pcscd.rules`) that fixes this. If
  you installed before that was added, re-run `install.sh` (or add the rule and
  `sudo systemctl restart polkit pcscd`).
- **No sound / wrong output** — check the DAC is up: `aplay -l` should list a
  `BossDAC` card (if not, the overlay isn't loaded — re-run `install.sh` and
  reboot). Then `wpctl status` should show the DAC's sink (`Built-in Audio
  Stereo`) starred as default; fix with `wpctl set-default <SINK_ID>`. Test
  with `mpv <some-audio-url>`.
- **Tag reads but nothing plays** — watch the logs
  (`journalctl --user -u nfc-player -f`): an unknown UID means the sheet row
  doesn't match (the UID must match exactly, no spaces); a player error means
  the URL isn't a streamable audio file.
