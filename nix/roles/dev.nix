# A headless build box for Rust workspaces and long-running coding agents.
#
# Deliberately imperative about toolchains and package managers: the repos this
# box builds pin their own toolchain in rust-toolchain.toml, and the agents
# install their own tools. Nix owns the *environment*, not the toolchain --
# which is the opposite of the usual advice and correct here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.dev;
in
{
  options.roles.dev = {
    enable = lib.mkEnableOption "Rust and AI-coding-agent development box";

    user = lib.mkOption {
      type = lib.types.str;
      default = "default-user";
      description = "Account the workspace belongs to and the agents run as.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/dev-secrets/env";
      description = ''
        KEY=value file rendered from nix/hosts/<machine>/secrets.env.tpl by
        `just secrets <machine>` and sourced into interactive shells. Owned by
        `user`, mode 0600, and never in the Nix store -- the values exist only
        inside the pipe that installs it.
      '';
    };

    workspace = lib.mkOption {
      type = lib.types.str;
      default = "/srv/work";
      description = ''
        Persistent scratch for clones, target/ dirs, ~/.cargo and ~/.rustup.
        Deliberately outside the home directory so it can become its own
        dataset or a bind mount from the Proxmox host later without moving
        anything.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # A predicate naming the one package, not a blanket allowUnfree, so an
    # accidental unfree dependency somewhere else still fails loudly.
    nixpkgs.config.allowUnfreePredicate = p: builtins.elem (lib.getName p) [ "claude-code" ];

    environment.systemPackages = with pkgs; [
      # rustup rather than fenix/rust-overlay: this box builds repos that pin
      # their own toolchain in rust-toolchain.toml, and rustup is the only one
      # that reads that file on its own. The usual objection -- that rustup's
      # downloads want /lib64/ld-linux-x86-64.so.2, which NixOS has not got --
      # does not apply: pkgs.rustup patchelfs every toolchain it fetches.
      rustup

      # What the `cc` crate and every -sys crate reach for.
      stdenv.cc
      gnumake
      pkg-config
      openssl.dev
      zlib

      # Available, but NOT wired in globally -- see the note on RUSTFLAGS below.
      mold
      sccache

      cargo-nextest
      cargo-edit
      cargo-watch

      # The agents, and the multiplexer they live in.
      herdr
      claude-code
      nodejs_22
      uv

      git
      git-lfs
      ripgrep
      fd
      jq
      just
      tmux
      helix
    ];

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    # Non-negotiable on an agent box. Agents run `npm -g`, `uv tool install`
    # and download prebuilt language servers constantly, none of which are
    # patchelfed; without nix-ld every one of them dies on a missing dynamic
    # loader.
    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        openssl
        zlib
        stdenv.cc.cc.lib
      ];
    };

    environment.variables = {
      RUSTUP_HOME = "${cfg.workspace}/rustup";
      CARGO_HOME = "${cfg.workspace}/cargo";
      # One shared target/ off $HOME, so a 200G rootfs is not eaten by a
      # per-clone copy of every dependency.
      CARGO_TARGET_DIR = "${cfg.workspace}/target";

      SCCACHE_DIR = "${cfg.workspace}/sccache";
      SCCACHE_CACHE_SIZE = "40G";

      # The declarative package is the only updater. Left to itself the
      # vendored auto-updater rewrites the binary out from under Nix.
      DISABLE_AUTOUPDATER = "1";
    };

    # Deliberately NOT set here: RUSTC_WRAPPER (sccache) and RUSTFLAGS (mold).
    #
    # Cargo does not merge RUSTFLAGS with a repo's [build] rustflags, it
    # REPLACES it -- and ipid's eBPF crate builds core from source via its own
    # .cargo/config.toml. A fleet-wide RUSTFLAGS would silently break it.
    # Opt in per repo instead:
    #
    #   [target.x86_64-unknown-linux-gnu]
    #   linker = "clang"
    #   rustflags = ["-C", "link-arg=-fuse-ld=mold"]
    #
    # or per shell: `env RUSTC_WRAPPER=sccache cargo build`.

    # Claude Code's own precedence puts CLAUDE_CODE_OAUTH_TOKEN below
    # ANTHROPIC_API_KEY and above an interactive login, so this file is the
    # unattended fallback and `claude auth login` still wins nothing back from
    # it -- an interactive login simply is not consulted while the token is
    # set. Interactive shells only: the agents are started by a person in a
    # herdr pane, not by a system unit.
    #
    # POSIX on purpose. NixOS translates environment.interactiveShellInit into
    # fish with babelfish, so one snippet covers both shells on this box.
    environment.interactiveShellInit = ''
      if [ -r ${cfg.secretsFile} ]; then
        set -a
        . ${cfg.secretsFile}
        set +a
      fi
    '';

    systemd.tmpfiles.rules = [
      "d ${cfg.workspace} 0755 ${cfg.user} users - -"
      "d ${cfg.workspace}/target 0755 ${cfg.user} users - -"
      "d ${cfg.workspace}/sccache 0755 ${cfg.user} users - -"
      "d ${builtins.dirOf cfg.secretsFile} 0700 ${cfg.user} users - -"
    ];

    nix.settings = {
      # `nixos-rebuild --target-host default-user@...` copies a closure signed
      # by nothing this box already trusts, so the receiving user has to be
      # trusted. It grants nothing new: base.nix already gives default-user
      # passwordless wheel sudo.
      trusted-users = [
        "root"
        cfg.user
      ];

      # 12 cores, but rustc parallelises internally. Six jobs of two keeps the
      # box answering SSH while a build runs.
      max-jobs = 6;
      cores = 2;

      # Do NOT add auto-allocate-uids here. It hands out UIDs outside an
      # unprivileged CT's 65536-entry idmap and builds then die with
      # "cannot kill processes for uid '872415232'".
    };

    # An always-on box that builds all day: keep the store off the 200G.
    nix.gc.options = lib.mkForce "--delete-older-than 14d";
  };
}
