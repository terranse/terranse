# Proves the registry produces a message naming the offender and listing the
# alternatives, rather than a bare "attribute missing".
{ lib, pkgs }:
let
  registry = import ../lib/registry.nix { inherit lib; };

  # Paths, not real modules -- nothing here is evaluated as a NixOS module.
  fake = {
    base = ./registry.nix;
    video = ./registry.nix;
  };

  message = registry.unknownRoleMessage fake "htpc" [ "kiosc" ];
  expected =
    "nix/machines.nix: machine 'htpc' lists unknown role(s): kiosc. "
    + "Valid roles are: base, video.";

  bad = builtins.tryEval (registry.modulesFor fake "htpc" [ { name = "kiosc"; } ]);
  good = registry.modulesFor fake "htpc" [ { name = "video"; } ];

  unknown = registry.unknownRoleNames fake [
    { name = "base"; }
    { name = "kiosc"; }
  ];
in
assert message == expected;
assert !bad.success;
assert good == [ ./registry.nix ];
assert unknown == [ "kiosc" ];
pkgs.runCommand "registry-test" { } "touch $out"
