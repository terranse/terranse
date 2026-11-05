# The account `just deploy` and CI push closures through. It is deliberately
# not in wheel: base.nix lets wheel sudo without a password, and this host
# asks wheel for one. The staged-updates role grants it exactly one sudo rule,
# NOPASSWD for htpc-stage, and that is all the privilege it has.
#
# Its key is the fleet key, the one default-user already accepts, so there is
# one key to rotate and nothing new to keep out of git.
{ config, ... }:
{
  users.users.deploy = {
    isNormalUser = true;
    description = "closure delivery";
    openssh.authorizedKeys.keys = config.users.users.default-user.openssh.authorizedKeys.keys;
  };
}
