# name -> module path. Adding a role is adding one line here and one file
# next to it; nothing else in the flake needs to know.
{
  android = ./android.nix;
  base = ./base.nix;
  desktop = ./desktop.nix;
  dev = ./dev.nix;
  home-player = ./home-player.nix;
  night-updates = ./night-updates.nix;
  staged-updates = ./staged-updates.nix;
  update-alerts = ./update-alerts.nix;
  video = ./video.nix;
}
