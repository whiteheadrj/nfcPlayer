#!/usr/bin/env bash
# Installer for the NFC book audio player. Run ON THE RASPBERRY PI:
#   bash install.sh
set -euo pipefail

APP_DIR="$HOME/nfc-player"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing packages (pcscd, ACR122U driver, pyscard, mpv)..."
sudo apt-get update
sudo apt-get install -y pcscd pcsc-tools libacsccid1 python3-pyscard mpv

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
# Modern pcsc-lite (Debian trixie and newer) gates the daemon behind polkit,
# which only allows an active desktop session by default. A boot service is an
# inactive session and gets "SCardEstablishContext: Access denied" — which makes
# the player crash-loop on boot — without this rule.
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

echo "==> Installing the app to $APP_DIR..."
mkdir -p "$APP_DIR"
cp "$SRC_DIR/nfc_player.py" "$APP_DIR/"

echo "==> Installing the systemd user service..."
mkdir -p "$HOME/.config/systemd/user"
cp "$SRC_DIR/nfc-player.service" "$HOME/.config/systemd/user/"
# Let the user service run without an active login session (e.g. after reboot).
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now nfc-player

echo
echo "Done! The player is running and will start automatically on boot."
echo
echo "  Logs:          journalctl --user -u nfc-player -f"
echo "  Register tags: systemctl --user stop nfc-player"
echo "                 python3 $APP_DIR/nfc_player.py --register"
echo "                 systemctl --user start nfc-player"
