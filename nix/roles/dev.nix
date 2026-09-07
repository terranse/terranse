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
      # Deliberately no CARGO_TARGET_DIR. One shared target/ would save disk,
      # but cargo takes a lock per target directory -- so several agents
      # building at once would serialise against each other, on the one
      # machine that exists to build several things at once. Disk is the
      # cheaper resource here.

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

    # rustup with no default toolchain makes a bare `cargo` fail, and a repo
    # without a rust-toolchain.toml has nothing to trigger an install. A
    # one-off rather than a recurring unit: it has exactly one thing to do, and
    # once RUSTUP_HOME has a default it never needs to run again. Everything
    # after that is the repos' business -- a rust-toolchain.toml still wins,
    # because rustup reads it per invocation.
    systemd.services.rustup-default-toolchain = {
      description = "Install a default Rust toolchain for ${cfg.user}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Guarded on the toolchains directory, not on settings.toml: merely
      # running `rustup --version` creates RUSTUP_HOME and settings.toml with
      # no toolchain in it, so that file proves nothing. Once a toolchain is
      # installed this is skipped, and upgrading is `rustup update` by hand
      # rather than a surprise on boot.
      unitConfig.ConditionDirectoryNotEmpty = "!${cfg.workspace}/rustup/toolchains";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        RemainAfterExit = true;
      };
      environment = {
        RUSTUP_HOME = "${cfg.workspace}/rustup";
        CARGO_HOME = "${cfg.workspace}/cargo";
      };
      path = [
        pkgs.rustup
        pkgs.gitMinimal
      ];
      script = "rustup toolchain install stable --profile default --no-self-update";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.workspace} 0755 ${cfg.user} users - -"
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
