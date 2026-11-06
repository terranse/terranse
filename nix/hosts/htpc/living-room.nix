# What this box needs because of what it is plugged into: the ZhenYe BLE remote
# on its USB dongle, and a Philips TV on DisplayPort that passes sound on to the
# Marantz receiver over ARC.
{ pkgs, ... }:
let
  # The remote's USB dongle (nRF, "ZhenYe Tech BLE Remote").
  remoteVendor = "1915";
  remoteProduct = "1001";
in
{
  # The remote's OK key sends HID consumer usage 0x41 (Menu Pick), which the
  # kernel calls KEY_SELECT. Nothing on the box treats that as "activate", so
  # OK did nothing outside air-mouse mode. Enter is what every app here
  # understands, Home Player, Android and Moonlight alike.
  services.udev.extraHwdb = ''
    evdev:input:b0003v${remoteVendor}p${remoteProduct}*
     KEYBOARD_KEY_c0041=enter
  '';

  # After one resume the dongle started answering every 1 ms poll with an
  # oversized packet (`usb 1-2: input irq status -75`, a thousand a second), so
  # no key from the remote arrived until it was re-enumerated. Re-enumerate it
  # on every resume; the remote reconnects within a second.
  powerManagement.resumeCommands = ''
    for dev in /sys/bus/usb/devices/*; do
      if [ "$(cat "$dev/idVendor" 2>/dev/null)" = ${remoteVendor} ] \
        && [ "$(cat "$dev/idProduct" 2>/dev/null)" = ${remoteProduct} ]; then
        echo 0 >"$dev/authorized"
        ${pkgs.coreutils}/bin/sleep 1
        echo 1 >"$dev/authorized"
      fi
    done
  '';

  # Sound goes out over DisplayPort to the TV. Left alone, WirePlumber ranks
  # the built-in card's analog profile above HDMI (its speaker port reports
  # "unknown" rather than "unplugged") and makes any USB audio device the
  # default, so nothing reached the TV. Pin the card to HDMI, even when the TV
  # is off at boot, and make that sink win.
  services.pipewire.wireplumber.extraConfig."51-htpc-hdmi-audio" = {
    "monitor.alsa.rules" = [
      {
        matches = [ { "device.name" = "alsa_card.pci-0000_00_1f.3"; } ];
        actions.update-props = {
          "api.acp.auto-profile" = false;
          "device.profile" = "output:hdmi-stereo";
        };
      }
      {
        matches = [ { "node.name" = "~alsa_output.pci-0000_00_1f.3.hdmi-*"; } ];
        actions.update-props = {
          "priority.session" = 2000;
          "priority.driver" = 2000;
        };
      }
    ];
  };
}
