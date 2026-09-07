# The role registry is a name -> module-path index and nothing more. NixOS
# modules already *are* roles: they carry their own typed options and
# assertions, and two roles touching the same option merge or conflict at
# evaluation time. Building a schema layer on top of that would reimplement
# the module system badly.
#
# The one thing the module system does *not* give us is a decent error for a
# typo'd role name -- a bare `attribute 'kiosc' missing` names neither the
# machine nor the alternatives. That is all this file exists to fix, and it is
# split out from flake.nix so the message itself is testable.
{ lib }:
let
  # Role names listed by a machine that the registry does not know about.
  unknownRoleNames =
    registry: roles: lib.subtractLists (builtins.attrNames registry) (map (r: r.name) roles);

  # Pure, so nix/tests/registry.nix can assert the exact text. `throw` is not
  # introspectable, which is why the message is built separately from the
  # throwing.
  unknownRoleMessage =
    registry: hostname: unknown:
    "nix/machines.nix: machine '${hostname}' lists unknown role(s): "
    + lib.concatStringsSep ", " unknown
    + ". Valid roles are: "
    + lib.concatStringsSep ", " (builtins.attrNames registry)
    + ".";
in
{
  inherit unknownRoleNames unknownRoleMessage;

  modulesFor =
    registry: hostname: roles:
    let
      unknown = unknownRoleNames registry roles;
    in
    if unknown == [ ] then
      map (r: registry.${r.name}) roles
    else
      throw (unknownRoleMessage registry hostname unknown);
}
