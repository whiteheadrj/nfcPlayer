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

echo "==> Enabling the InnoMaker HiFi DAC HAT (PCM5122)..."
# The HAT has no ID EEPROM, so its device-tree overlay (the Allo Boss one,
# per InnoMaker's manual) must be enabled by hand. Onboard audio is disabled
# so the DAC is the only analog output.
BOOT_CFG=/boot/firmware/config.txt
[ -f "$BOOT_CFG" ] || BOOT_CFG=/boot/config.txt
NEED_REBOOT=0
if ! grep -q "^dtoverlay=allo-boss-dac-pcm512x-audio" "$BOOT_CFG"; then
  sudo sed -i 's/^dtparam=audio=on/#dtparam=audio=on/' "$BOOT_CFG"
  echo "dtoverlay=allo-boss-dac-pcm512x-audio" | sudo tee -a "$BOOT_CFG" >/dev/null
  NEED_REBOOT=1
fi

echo "==> Making the DAC the default audio output..."
if aplay -l 2>/dev/null | grep -q BossDAC && command -v wpctl >/dev/null 2>&1; then
  # PipeWire: find the BossDAC sink and set it as default (WirePlumber
  # remembers this across reboots).
  for id in $(wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' \
              | grep -oE '[0-9]+\.' | tr -d '.'); do
    if wpctl inspect "$id" 2>/dev/null | grep -q 'alsa.card_name = "BossDAC"'; then
      wpctl set-default "$id"
      wpctl set-volume "$id" 0.3
      wpctl set-mute "$id" 0
      echo "    BossDAC (sink $id) is now the default output at 30% volume."
      break
    fi
  done
else
  echo "    DAC not visible yet — it appears after the reboot below."
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
if [ "$NEED_REBOOT" = 1 ]; then
  echo
  echo "  REBOOT REQUIRED to bring up the DAC HAT, then run 'bash install.sh'"
  echo "  once more (it's idempotent) to set it as the default output."
fi
echo
echo "  Logs:          journalctl --user -u nfc-player -f"
echo "  Register tags: systemctl --user stop nfc-player"
echo "                 python3 $APP_DIR/nfc_player.py --register"
echo "                 systemctl --user start nfc-player"
