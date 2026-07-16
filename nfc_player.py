#!/usr/bin/env python3
"""NFC audio player for Raspberry Pi.

Tap an NFC tag on an ACR122U reader; the tag's UID is looked up in a
Google Sheet (columns: Tag, Book Title, Link) and the audio URL from
that row is streamed with mpv through the Pi's 3.5mm jack.

Modes:
    python3 nfc_player.py             run the player
    python3 nfc_player.py --register  just print tag UIDs (for filling in the sheet)
"""

import csv
import io
import logging
import os
import queue
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.request

from smartcard.CardMonitoring import CardMonitor, CardObserver
from smartcard.util import toHexString

# ---------------------------------------------------------------------------
# Configuration (override via environment variables, e.g. in the systemd unit)
# ---------------------------------------------------------------------------
SHEET_ID = os.environ.get("SHEET_ID", "1EW7mGv9IMcwiIqwEJGDhc8e-PXXOceAWLizcIYIbi-U")
SHEET_REFRESH_SECONDS = int(os.environ.get("SHEET_REFRESH_SECONDS", "300"))
# Extra args for mpv, e.g. AUDIO_DEVICE="alsa/hw:0,0" to force an output.
AUDIO_DEVICE = os.environ.get("AUDIO_DEVICE", "")
# Tapping the tag that is currently playing stops it (1) or restarts it (0).
SAME_TAG_STOPS = os.environ.get("SAME_TAG_STOPS", "1") == "1"
PLAYER_CMD = os.environ.get("PLAYER_CMD", "mpv --no-video --really-quiet")

CSV_URL = f"https://docs.google.com/spreadsheets/d/{SHEET_ID}/export?format=csv"

GET_UID_APDU = [0xFF, 0xCA, 0x00, 0x00, 0x00]

log = logging.getLogger("nfc-player")


def normalize_uid(uid: str) -> str:
    """Canonical form of a tag UID: uppercase hex, no separators."""
    return re.sub(r"[^0-9A-F]", "", uid.upper())


def direct_audio_url(url: str) -> str:
    """Rewrite common share links to something a media player can stream."""
    url = url.strip()
    m = re.search(r"drive\.google\.com/file/d/([\w-]+)", url)
    if not m:
        m = re.search(r"drive\.google\.com/open\?id=([\w-]+)", url)
    if m:
        return f"https://drive.google.com/uc?export=download&id={m.group(1)}"
    if "dropbox.com" in url:
        url = url.replace("?dl=0", "?dl=1").replace("&dl=0", "&dl=1")
        if "dl=1" not in url and "dl.dropboxusercontent" not in url:
            url += ("&" if "?" in url else "?") + "dl=1"
    return url


class TagTable:
    """UID -> (title, url) mapping loaded from the Google Sheet."""

    def __init__(self):
        self._lock = threading.Lock()
        self._table = {}
        self._loaded_once = False

    def refresh(self) -> bool:
        try:
            with urllib.request.urlopen(CSV_URL, timeout=15) as resp:
                text = resp.read().decode("utf-8", errors="replace")
        except Exception as exc:
            log.warning("Could not fetch sheet: %s", exc)
            return False

        rows = list(csv.reader(io.StringIO(text)))
        if not rows:
            log.warning("Sheet is empty")
            return False

        header = [h.strip().lower() for h in rows[0]]

        def col(*names, default):
            for name in names:
                if name in header:
                    return header.index(name)
            return default

        tag_col = col("tag", "uid", "id", default=0)
        title_col = col("book title", "title", "book", "name", default=1)
        link_col = col("link", "url", "audio", "audio url", default=2)

        table = {}
        for row in rows[1:]:
            if len(row) <= max(tag_col, link_col):
                continue
            uid = normalize_uid(row[tag_col])
            url = row[link_col].strip()
            if not uid or not url:
                continue
            title = row[title_col].strip() if len(row) > title_col else ""
            table[uid] = (title or uid, direct_audio_url(url))

        with self._lock:
            self._table = table
            self._loaded_once = True
        log.info("Sheet loaded: %d tag(s)", len(table))
        return True

    def lookup(self, uid: str):
        with self._lock:
            return self._table.get(uid)

    @property
    def loaded(self) -> bool:
        with self._lock:
            return self._loaded_once


class Player:
    """Wraps a single mpv subprocess streaming the current audio URL."""

    def __init__(self):
        self._proc = None
        self._current_uid = None

    def _base_cmd(self):
        cmd = shlex.split(PLAYER_CMD)
        if AUDIO_DEVICE:
            cmd.append(f"--audio-device={AUDIO_DEVICE}")
        return cmd

    def is_playing(self, uid=None) -> bool:
        if self._proc is None or self._proc.poll() is not None:
            return False
        return uid is None or uid == self._current_uid

    def play(self, uid: str, title: str, url: str):
        self.stop()
        log.info("Playing '%s' (%s)", title, url)
        try:
            self._proc = subprocess.Popen(self._base_cmd() + [url])
            self._current_uid = uid
        except FileNotFoundError:
            log.error("Player binary not found — is mpv installed?")

    def stop(self):
        if self._proc is not None and self._proc.poll() is None:
            log.info("Stopping playback")
            self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        self._proc = None
        self._current_uid = None


class UidCollector(CardObserver):
    """Reads the UID of every card presented and puts it on a queue."""

    def __init__(self, uid_queue: "queue.Queue[str]"):
        self.uid_queue = uid_queue

    def update(self, observable, actions):
        added, _removed = actions
        for card in added:
            try:
                conn = card.createConnection()
                conn.connect()
                data, sw1, sw2 = conn.transmit(GET_UID_APDU)
                conn.disconnect()
                if sw1 == 0x90:
                    self.uid_queue.put(normalize_uid(toHexString(data)))
                else:
                    log.warning("Reader returned status %02X %02X", sw1, sw2)
            except Exception as exc:
                log.warning("Could not read tag: %s", exc)


def run_register_mode():
    print("Register mode: tap tags to print their UIDs (Ctrl-C to quit).")
    print("Paste each UID into the 'Tag' column of the Google Sheet.\n")
    uids: "queue.Queue[str]" = queue.Queue()
    monitor = CardMonitor()
    monitor.addObserver(UidCollector(uids))
    try:
        while True:
            print(f"Tag UID: {uids.get()}")
    except KeyboardInterrupt:
        pass


def run_player():
    tags = TagTable()
    tags.refresh()

    player = Player()
    uids: "queue.Queue[str]" = queue.Queue()
    monitor = CardMonitor()
    monitor.addObserver(UidCollector(uids))

    def shutdown(signum, frame):
        log.info("Shutting down")
        player.stop()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    log.info("Ready — tap a tag")
    last_refresh = time.monotonic()
    last_uid, last_time = None, 0.0

    while True:
        try:
            uid = uids.get(timeout=5)
        except queue.Empty:
            if time.monotonic() - last_refresh > SHEET_REFRESH_SECONDS:
                tags.refresh()
                last_refresh = time.monotonic()
            continue

        # Debounce chattering reads of the same physical tap.
        now = time.monotonic()
        if uid == last_uid and now - last_time < 2.0:
            continue
        last_uid, last_time = uid, now

        entry = tags.lookup(uid)
        if entry is None:
            # Maybe the row was just added — refresh and retry once.
            tags.refresh()
            last_refresh = time.monotonic()
            entry = tags.lookup(uid)
        if entry is None:
            log.warning("Unknown tag %s — add it to the sheet's Tag column", uid)
            continue

        title, url = entry
        if SAME_TAG_STOPS and player.is_playing(uid):
            player.stop()
        else:
            player.play(uid, title, url)


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    if "--register" in sys.argv:
        run_register_mode()
    else:
        run_player()


if __name__ == "__main__":
    main()
