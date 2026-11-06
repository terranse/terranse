# The HTPC's update source, on the LAN: builds the system nightly, serves the
# signed binary cache and its pointers, hosts the bare git repos the laptop
# pushes to, and netboots the HTPC's rescue image to its MAC only.
#
# Nothing here involves GitHub or GitLab. The laptop pushes terranse and Home
# Player to git@<host>:/srv/git/<repo>.git; the nightly job checks out the
# tracked terranse branch from there, bumps and checks it with
# scripts/nightly.sh, publishes through scripts/ship.sh --no-push, and
# force-pushes what it built to its own branch, nightly/<machine>. It never
# writes to the branch people push to. `just deploy htpc` starts the same job.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.update-host;

  cacheDir = "/srv/nix-cache";
  gitRoot = "/srv/git";
  # Each repo and the branch it is used on, which becomes its HEAD: what a
  # plain clone checks out. Set on every boot, so an existing repo follows too.
  repos = {
    terranse = cfg.branch;
    home-player = "master";
  };
  nightlyHome = "/var/lib/nightly-build";
  checkout = "${nightlyHome}/terranse";
  # Keys sshd reads at runtime, one file per user (%u). Only `git` has one: the
  # nightly job's key, made on first boot and so unknown at evaluation.
  runtimeKeysDir = "/var/lib/nixhost-git-keys";
  apiPort = 8099;
  pixiecorePort = 8081;
  gitShell = "${pkgs.git}/bin/git-shell";

  setup = pkgs.writeShellApplication {
    name = "nixhost-git-setup";
    runtimeInputs = with pkgs; [
      coreutils
      git
      openssh
      util-linux
    ];
    text = ''
      ${lib.concatStrings (
        lib.mapAttrsToList (repo: branch: ''
          dir=${lib.escapeShellArg "${gitRoot}/${repo}.git"}
          if [ ! -e "$dir/HEAD" ]; then
            runuser -u git -- git init -q --bare --initial-branch=${lib.escapeShellArg branch} "$dir"
            echo "created $dir"
          fi
          runuser -u git -- git -C "$dir" symbolic-ref HEAD ${lib.escapeShellArg "refs/heads/${branch}"}
        '') repos
      )}

      key="${nightlyHome}/.ssh/id_ed25519"
      if [ ! -e "$key" ]; then
        runuser -u nightly -- install -d -m 0700 "${nightlyHome}/.ssh"
        runuser -u nightly -- ssh-keygen -q -t ed25519 -N "" -C "nightly@${config.networking.hostName}" -f "$key"
        echo "made the nightly job's git key"
      fi
      # Rewritten every boot, so it always matches the key on disk.
      install -d -m 0755 ${runtimeKeysDir}
      printf 'restrict %s\n' "$(cat "$key.pub")" >${runtimeKeysDir}/git.new
      chmod 0644 ${runtimeKeysDir}/git.new
      mv ${runtimeKeysDir}/git.new ${runtimeKeysDir}/git
    '';
  };

  nightly = pkgs.writeShellApplication {
    name = "nixhost-nightly";
    runtimeInputs = with pkgs; [
      coreutils
      git
      openssh
    ];
    text = ''
      # This host's own key, read from the file sshd serves: the job trusts
      # exactly it, with no trust-on-first-use.
      hostkey="$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
      install -d -m 0700 "$HOME/.ssh"
      printf '%s %s\n' "localhost,${config.networking.hostName},${config.networking.hostName}.edholm.cc" \
        "$hostkey" >"$HOME/.ssh/known_hosts"

      # The env file carries the signing key as a value; ship.sh wants a file.
      # It goes to the unit's private runtime directory, which systemd removes
      # when the job ends, and leaves the environment before anything else runs.
      if [ -z "''${NIX_SIGNING_KEY:-}" ]; then
        echo "nixhost-nightly: no NIX_SIGNING_KEY in ${cfg.environmentFile}; run \`just secrets\` for this host" >&2
        exit 1
      fi
      (
        umask 077
        printf '%s\n' "$NIX_SIGNING_KEY" >"$RUNTIME_DIRECTORY/signing.key"
      )
      unset NIX_SIGNING_KEY
      export SIGNING_KEY_FILE="$RUNTIME_DIRECTORY/signing.key"

      if [ ! -e "${checkout}/.git" ]; then
        git clone -q --branch "$NIGHTLY_BRANCH" "git@localhost:${gitRoot}/terranse.git" "${checkout}"
      fi
      cd "${checkout}"
      # The tracked branch as it is now, force-pushes included, so the
      # nightly.sh that runs is the one that was pushed. A checkout someone
      # left dirty stops here; nightly.sh says so too.
      git fetch -q origin "+refs/heads/$NIGHTLY_BRANCH:refs/remotes/origin/$NIGHTLY_BRANCH"
      git checkout -q -B "$NIGHTLY_BRANCH" "refs/remotes/origin/$NIGHTLY_BRANCH"
      # nightly.sh bumps, checks, has ship.sh sign and publish, and pushes what
      # it built to nightly/<machine>. It is the checkout's own copy, so it
      # changes with the repo.
      ./scripts/nightly.sh ${lib.escapeShellArg cfg.machine}
    '';
  };
in
{
  options.roles.update-host = {
    enable = lib.mkEnableOption "nightly HTPC builds, the binary cache, the LAN git repos and HTPC netboot";

    machine = lib.mkOption {
      type = lib.types.str;
      default = "htpc";
      description = "The machine the nightly job builds and publishes.";
    };

    buildTime = lib.mkOption {
      type = lib.types.str;
      default = "01:30";
      description = "Local time of the nightly build. The HTPC wakes at 03:30 to fetch it.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branch of the LAN terranse repo the nightly job builds. Read only: the result goes to nightly/<machine>.";
    };

    netbootMac = lib.mkOption {
      type = lib.types.strMatching "([0-9a-f]{2}:){5}[0-9a-f]{2}";
      example = "bc:e9:2f:86:35:3b";
      description = "The only MAC that gets a netboot answer, lowercase. Every other client gets a 404.";
    };

    netbootImage = lib.mkOption {
      type = lib.types.package;
      description = "Directory with bzImage, initrd and cmdline: the flake's htpc-netboot package.";
    };

    haUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://home.edholm.cc:8123";
      description = "Home Assistant, for the stale-build alert nightly.sh sends.";
    };

    notifyService = lib.mkOption {
      type = lib.types.str;
      example = "notify.mobile_app_pixel_8";
      description = "Home Assistant notify service that reaches the phone.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixhost-secrets/env";
      description = ''
        HA_TOKEN=... and NIX_SIGNING_KEY=..., rendered from
        nix/hosts/<host>/secrets.env.tpl by `just secrets` and read by systemd
        only. Never in the repo or the Nix store.
      '';
    };

    gitAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.users.users.default-user.openssh.authorizedKeys.keys;
      defaultText = "the fleet key";
      description = "Keys that may clone and push the LAN repos. The nightly job's own key is added at boot.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ---- git ------------------------------------------------------------------
    users.groups.git = { };
    users.users.git = {
      isSystemUser = true;
      group = "git";
      home = gitRoot;
      # Pushes and fetches only: git-shell refuses everything else, and
      # `restrict` takes away forwarding and a terminal.
      shell = gitShell;
      openssh.authorizedKeys.keys = map (k: "restrict ${k}") cfg.gitAuthorizedKeys;
    };
    environment.shells = [ gitShell ];
    services.openssh.authorizedKeysFiles = [ "${runtimeKeysDir}/%u" ];

    systemd.services.nixhost-git-setup = {
      description = "Create the LAN git repos and the nightly job's key";
      wantedBy = [ "multi-user.target" ];
      before = [ "nixhost-nightly.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe setup;
      };
    };

    # ---- the binary cache -------------------------------------------------------
    # Static files written by ship.sh; the HTPC checks every signature itself,
    # so plain HTTP on the LAN is enough.
    services.nginx = {
      enable = true;
      virtualHosts.nix-cache = {
        listen = [
          {
            addr = "0.0.0.0";
            port = 8080;
          }
        ];
        root = cacheDir;
      };
    };

    # ---- the nightly build ------------------------------------------------------
    users.groups.nightly = { };
    users.users.nightly = {
      isSystemUser = true;
      group = "nightly";
      home = nightlyHome;
      createHome = true;
      # VM tests need /dev/kvm; nightly.sh skips them loudly when it is absent.
      extraGroups = [ "kvm" ];
    };
    # `nix store sign` adds signatures to the local store, which the daemon
    # allows only to trusted users. This box exists to run this job.
    nix.settings.trusted-users = [ "nightly" ];

    # The container has a 200G disk holding the store, the cache and the git
    # repos. ship.sh refuses to publish with less than 20 GiB free on the cache,
    # so nix starts collecting garbage during a build once free space falls
    # under 25 GiB, leaving that margin, and stops at 50 GiB: enough for a
    # night's build of the HTPC and its checks without collecting on every one.
    # The nightly job alerts above 80% used (40 GiB free), before either.
    nix.settings.min-free = 25 * 1024 * 1024 * 1024;
    nix.settings.max-free = 50 * 1024 * 1024 * 1024;

    systemd.tmpfiles.rules = [
      "d ${gitRoot} 0755 git git -"
      "d ${cacheDir} 0755 nightly nightly -"
      "d ${nightlyHome} 0700 nightly nightly -"
    ];

    systemd.services.nixhost-nightly = {
      description = "Nightly ${cfg.machine} build: bump, check, sign, publish";
      after = [
        "network-online.target"
        "nixhost-git-setup.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "nixhost-git-setup.service" ];
      # A deploy must never start a build.
      restartIfChanged = false;
      path = [
        config.nix.package
      ]
      ++ (with pkgs; [
        bash
        coreutils
        curl
        findutils
        gawk
        git
        gnugrep
        gnused
        jq
        openssh
      ]);
      environment = {
        NIGHTLY_BRANCH = cfg.branch;
        NIX_CACHE_DIR = cacheDir;
        NIGHTLY_STATE_DIR = "${nightlyHome}/state";
        HA_URL = cfg.haUrl;
        HA_NOTIFY_SERVICE = cfg.notifyService;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "nightly";
        Group = "nightly";
        # `-` so a host without the file still runs the unit, which then says
        # what is missing.
        EnvironmentFile = "-${cfg.environmentFile}";
        RuntimeDirectory = "nixhost-nightly";
        RuntimeDirectoryMode = "0700";
        ExecStart = lib.getExe nightly;
        # A wedged build must not run into the next night.
        TimeoutStartSec = "20h";
      };
    };

    systemd.timers.nixhost-nightly = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${cfg.buildTime}:00";
        # A host that was down at 01:30 builds when it comes back.
        Persistent = true;
      };
    };

    # ---- netboot ----------------------------------------------------------------
    # Pixiecore answers PXE as proxy DHCP alongside the router's DHCP server
    # (--dhcp-no-bind, so it never takes port 67 from anything) and asks the
    # API below whether to boot each client. NVMe is first in the HTPC's boot
    # order, so this only matters once its disk stops booting.
    systemd.services.nixhost-pxe-api = {
      description = "Pixiecore API: boot the HTPC's MAC, ignore everyone else";
      wantedBy = [ "multi-user.target" ];
      before = [ "pixiecore.service" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${pkgs.python3}/bin/python3"
          "-I"
          "${./pxe-api.py}"
          cfg.netbootMac
          "${cfg.netbootImage}"
          (toString apiPort)
        ];
        DynamicUser = true;
        Restart = "always";
      };
    };

    services.pixiecore = {
      enable = true;
      mode = "api";
      apiServer = "http://127.0.0.1:${toString apiPort}";
      dhcpNoBind = true;
      port = pixiecorePort;
      statusPort = pixiecorePort;
      # 67, 69 and 4011 UDP and the port above. The API stays on loopback.
      openFirewall = true;
    };

    networking.firewall.allowedTCPPorts = [ 8080 ];
  };
}
