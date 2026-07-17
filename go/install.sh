#!/usr/bin/env bash
# Installer for the Go NFC book audio player. Run ON THE RASPBERRY PI:
#   bash install.sh
#
# Installs a prebuilt static binary from dist/ (cross-compiled on any machine
# with `bash build.sh`) — no Go toolchain or dev headers needed on the Pi.
set -euo pipefail

APP_DIR="$HOME/nfc-player-go"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pick the binary matching this Pi's architecture.
case "$(uname -m)" in
  aarch64|arm64) BIN="nfcplayer-linux-arm64" ;;
  armv7l|armv6l|arm) BIN="nfcplayer-linux-armv7" ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
BIN_PATH="$SRC_DIR/dist/$BIN"
[ -f "$BIN_PATH" ] || { echo "Missing $BIN_PATH — run 'bash build.sh' first (on your dev machine)."; exit 1; }

echo "==> Installing runtime packages (pcscd, ACR122U driver, mpv)..."
sudo apt-get update
sudo apt-get install -y pcscd pcsc-tools libacsccid1 mpv

echo "==> Blacklisting kernel NFC modules that conflict with the ACR122U..."
sudo tee /etc/modprobe.d/blacklist-acr122u.conf >/dev/null <<'EOF'
install nfc /bin/false
install pn533 /bin/false
install pn533_usb /bin/false
EOF
sudo modprobe -r pn533_usb pn533 nfc 2>/dev/null || true

echo "==> Enabling the PC/SC smartcard daemon..."
sudo systemctl enable --now pcscd

echo "==> Granting PC/SC access to background/boot sessions (polkit)..."
# Modern pcsc-lite gates the daemon behind polkit, which only allows an active
# desktop session by default. A boot service (and SSH) counts as inactive and
# gets "SCardEstablishContext: Access denied" without this rule.
sudo tee /etc/polkit-1/rules.d/49-pcscd.rules >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id == "org.debian.pcsc-lite.access_pcsc" ||
      action.id == "org.debian.pcsc-lite.access_card") {
    return polkit.Result.YES;
  }
});
EOF
sudo systemctl restart polkit pcscd 2>/dev/null || true

echo "==> Routing audio to the 3.5mm headphone jack..."
if command -v wpctl >/dev/null 2>&1; then
  # PipeWire/WirePlumber: raspi-config can't set this — do it via the sink list.
  echo "    PipeWire detected. Set the jack as default output from the taskbar"
  echo "    volume icon, or: 'wpctl status' then 'wpctl set-default <SINK_ID>'."
else
  # Non-fatal: on some OS versions this is done in raspi-config instead.
  sudo raspi-config nonint do_audio 1 2>/dev/null || \
    echo "    (couldn't set automatically — use 'sudo raspi-config' > System > Audio)"
fi

echo "==> Installing the binary ($BIN) to $APP_DIR..."
mkdir -p "$APP_DIR"
install -m 0755 "$BIN_PATH" "$APP_DIR/nfcplayer"

echo "==> Installing the systemd user service..."
mkdir -p "$HOME/.config/systemd/user"
cp "$SRC_DIR/nfc-player-go.service" "$HOME/.config/systemd/user/"
# Let the user service run without an active login session (e.g. after reboot).
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now nfc-player-go

echo
echo "Done! The Go player is running and will start automatically on boot."
echo
echo "  Logs:          journalctl --user -u nfc-player-go -f"
echo "  Register tags: systemctl --user stop nfc-player-go"
echo "                 $APP_DIR/nfcplayer --register"
echo "                 systemctl --user start nfc-player-go"
