# Always applied, never listed in nix/machines.nix. Everything here is true of
# every terranse-managed NixOS machine: how you log in, how it names itself,
# and what it will accept from the outside.
#
# Deliberately plain config with no `roles.base` namespace: an implicit role
# has nothing to enable.
#
# Two things this file deliberately does NOT carry, because they are not true
# of every machine:
#   - the bootloader and the disk. A container has neither, and
#     `boot.loader.systemd-boot` conflicts outright with the initScript loader
#     an LXC uses. Both live in nix/profiles/metal.nix.
#   - `system.stateVersion`. It is a statement about which release a
#     *particular* machine's state was created under, so it lives in
#     nix/hosts/<name>/default.nix.
{ lib, pkgs, ... }:
{
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_GB.UTF-8";

  # DHCP on purpose: the lease is what registers the hostname with dnsmasq,
  # which is what makes <host>.edholm.cc resolve on the LAN. A static address
  # means no lease, no registration, and the name falls through to the
  # wildcard *.edholm.cc record pointing at the WAN IP.
  networking.useDHCP = lib.mkDefault true;

  # Same shell as the LXCs, so muscle memory carries across the fleet.
  programs.fish.enable = true;

  users.users.default-user = {
    isNormalUser = true;
    description = "terranse fleet account";
    shell = pkgs.fish;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkdwh5G9JuqNpThbxYqP7RBT9CQJ1fkFeOGuP1sUrXK"
    ];
  };

  # Passwordless wheel sudo matches how the LXCs accept `become: true`, which
  # is what lets root login stay disabled below. `users.mutableUsers` is left
  # at its default so `passwd default-user` on the console remains a recovery
  # route on a box with no other way in.
  security.sudo.wheelNeedsPassword = false;

  # CI's account. It gets no shell privileges of its own; the single sudo
  # entry it needs belongs to the staged-updates role, which is what owns that
  # command.
  users.users.deploy = {
    isNormalUser = true;
    description = "CI closure receiver";
    openssh.authorizedKeys.keys = [
      "REPLACE-WITH-htpc-deploy.pub-FROM-TASK-1"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # The builder's public half. A closure signed by it is accepted from an
    # untrusted user; anything else is refused. This is the whole reason a
    # stolen deploy key uploads bytes the box will not run, rather than
    # granting root.
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "REPLACE-WITH-cache-pub.pem-FROM-TASK-1"
    ];
  };

  # A machine fills its disk with old generations faster than anyone notices.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  # Forced off inside a container by container-config.nix, so this costs
  # nothing there and stays right for metal.
  nix.optimise.automatic = true;

  environment.systemPackages = with pkgs; [
    git
    htop
    ethtool
  ];
}
