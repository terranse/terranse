{
  description = "terranse -- the NixOS machines in the fleet";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative partitioning. It is what lets a machine be built and an
    # installer be produced before the machine physically exists. Imported by
    # nix/profiles/metal.nix only -- a container has no disk to partition.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      registry = import ./nix/lib/registry.nix { inherit lib; };
      roleModules = import ./nix/roles;
      profiles = import ./nix/profiles;
      machines = import ./nix/machines.nix;

      mkMachine =
        hostname:
        {
          system,
          roles ? [ ],
          kind ? "metal",
        }:
        lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs hostname; };
          modules =
            [
              # Firmware and a disk, or a container. Nothing else in the flake
              # branches on it. A typo names the machine and lists the valid
              # kinds rather than failing with a bare "attribute missing".
              (profiles.${kind} or (throw (
                "nix/machines.nix: machine '${hostname}' has unknown kind '${kind}'. "
                + "Valid kinds are: "
                + lib.concatStringsSep ", " (builtins.attrNames profiles)
                + "."
              )))
              ./nix/hosts/${hostname}
              roleModules.base
              { networking.hostName = hostname; }
            ]
            # A typo'd role name fails here with a message naming the offender,
            # not with a bare "attribute missing" three frames deeper.
            ++ registry.modulesFor roleModules hostname roles
            # Presence in the list is what turns a role on; `settings` splice
            # into that role's own namespace.
            ++ map (r: { roles.${r.name} = { enable = true; } // (r.settings or { }); }) roles;
        };

      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      nixosConfigurations = lib.mapAttrs mkMachine machines;

      # The rootfs tarballs for every container-kind machine, named
      # <machine>-lxc-template. Built from the SAME toplevel nixos-rebuild
      # later deploys, so the template and the running system can never be two
      # different things. Ship one with `just push-lxc-template <machine>`.
      packages.x86_64-linux = lib.mapAttrs' (
        name: cfg: lib.nameValuePair "${name}-lxc-template" cfg.config.system.build.tarball
      ) (lib.filterAttrs (name: _: (machines.${name}.kind or "metal") == "lxc") self.nixosConfigurations);

      # A broken role must fail the pipeline, not the machine: every machine's
      # toplevel is a check, so `nix flake check` builds what would be
      # deployed.
      checks.x86_64-linux =
        lib.mapAttrs' (
          name: cfg: lib.nameValuePair "machine-${name}" cfg.config.system.build.toplevel
        ) (lib.filterAttrs (_: cfg: cfg.pkgs.stdenv.hostPlatform.system == "x86_64-linux") self.nixosConfigurations)
        // {
          registry = import ./nix/tests/registry.nix { inherit lib pkgs; };
        };

      formatter.x86_64-linux = pkgs.nixfmt-tree;
    };
}
