# The two people who use this TV. Neither account has a password in Nix: the
# hashes would land in the store and in git. `just htpc-passwords` sets them
# on the box, and users.mutableUsers (left at its default) keeps them there.
{ lib, ... }:
{
  users.users.vuxna = {
    isNormalUser = true;
    description = "Vuxna";
    extraGroups = [ "wheel" ];
  };

  # No wheel, and no Home Player autostart: that belongs to the kiosk account.
  users.users.barn = {
    isNormalUser = true;
    description = "Barn";
  };

  # base.nix lets every wheel member sudo without a password because the
  # fleet's containers have nobody to type one. Here a person is in wheel, so
  # the password is back for them and the deploy account keeps its own rule.
  # mkForce because base.nix sets the same option at normal priority.
  security.sudo.wheelNeedsPassword = lib.mkForce true;
  security.sudo.extraRules = [
    {
      users = [ "default-user" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
