# Android apps on the TV through Waydroid. It runs on this machine rather than
# the gaming VM because Android needs a GPU Mesa can drive, and the VM's NVIDIA
# slice would leave it rendering in software.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.android;
  waydroid = config.virtualisation.waydroid.package;
  socketPath = "/run/android-launch.sock";

  # Needs root because it reaches into the container, so it runs as a service
  # of its own. The session can only send it one line, and anything that isn't
  # a package name or "home" is refused. It answers with one line: "ready" once
  # the app has drawn its first frame, "ok" for home, or "failed <reason>".
  android-launch-handler = pkgs.writeShellApplication {
    name = "android-launch-handler";
    runtimeInputs = [
      pkgs.coreutils
      waydroid
    ];
    text = ''
      # The reply goes to the socket, everything else to the journal. The app
      # must still open if the caller hangs up, so a closed socket is ignored.
      trap "" PIPE
      exec 3>&1 1>&2
      reply() { echo "$1" >&3 || true; }

      pkg=""
      read -r -t 5 -n 256 pkg || [ -n "$pkg" ] || exit 2

      # Android's Home takes the app's window away and hands the screen back.
      if [ "$pkg" = home ]; then
        waydroid shell -- input keyevent KEYCODE_HOME
        reply ok
        exit 0
      fi

      if ! [[ "$pkg" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]; then
        echo "android-launch: refused a request that is not a package name"
        exit 2
      fi

      # Android freezes when idle, and may still be booting right after login.
      # Each `waydroid shell` costs about a second, so the boot check and the
      # lookup share one.
      waydroid container unfreeze || true
      while :; do
        resolved=$(waydroid shell -- sh -c "[ \"\$(getprop sys.boot_completed)\" = 1 ] \
          && echo booted && cmd package resolve-activity --brief \
          -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $pkg" \
          2>/dev/null | tr -d '\r') || true
        [[ "$resolved" == booted* ]] && break
        if [ "$SECONDS" -ge 60 ]; then
          reply "failed boot-timeout"
          exit 1
        fi
        sleep 1
      done

      # It goes back into a command line below, so only a plain name will do.
      component=$(printf '%s\n' "$resolved" | tail -n 1)
      component_re='^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$'
      if ! [[ "$component" =~ $component_re ]]; then
        echo "android-launch: $pkg is not installed"
        reply "failed not-installed"
        exit 1
      fi

      # `waydroid app launch` can only open a small floating window, so start
      # the activity directly in fullscreen mode. The window then shows only
      # while this property names something other than the app, and an app it
      # does name stays invisible, hence the neutral value. `am start -W`
      # returns once the app's own first frame is drawn, but `waydroid shell`
      # exits 0 whatever happened, so the answer is read from its output.
      rc=0
      out=$(timeout 25 waydroid shell -- sh -c "setprop waydroid.active_apps home-player; \
        settings put global policy_control 'immersive.full=*'; \
        am start -W --windowingMode 1 -n '$component'" 2>&1) || rc=$?
      echo "$out"
      case "$out" in
        *"Status: ok"*) reply ready ;;
        *)
          if [ "$rc" -eq 124 ]; then
            reply "failed draw-timeout"
          else
            reply "failed start"
          fi
          exit 1
          ;;
      esac
    '';
  };

  # Waits for the answer, which comes after the app has drawn, so the caller
  # knows when to show it. Longer than the handler's own wait for the draw.
  android-launch = pkgs.writeShellScriptBin "android-launch" ''
    case "''${1:-}" in
      --home) request=home ;;
      *) request="''${1:-}" ;;
    esac
    answer=$(printf '%s\n' "$request" \
      | ${lib.getExe pkgs.socat} -t 30 - UNIX-CONNECT:${socketPath}) || true
    answer=''${answer%%$'\n'*}
    echo "$answer"
    case "$answer" in
      ready | ok) exit 0 ;;
      *) exit 1 ;;
    esac
  '';

  # F-Droid's build, as the store it replaces is the one thing it needs no
  # store for. F-Droid only keeps recent versions, so bumping this may be forced.
  aurora-store = pkgs.fetchurl {
    url = "https://f-droid.org/repo/com.aurora.store_76.apk";
    hash = "sha256-/Zx12Q0PSnwTK5tKWizxmSpF4DuNj/mIt9z7wNssTRE=";
  };

  # Separate windows are what hand the screen back to the kiosk when an app
  # closes. With a single Android window, leaving an app lands on Android's own
  # launcher instead. Kept in [properties] so image upgrades preserve it.
  set-window-mode = pkgs.writeShellScript "waydroid-set-window-mode" ''
    ${lib.getExe pkgs.gnused} -i \
      '/^\[properties\]$/a persist.waydroid.multi_windows = true' \
      /var/lib/waydroid/waydroid.cfg
    ${lib.getExe waydroid} upgrade --offline
  '';
in
{
  options.roles.android = {
    enable = lib.mkEnableOption "Android apps through Waydroid";

    imageType = lib.mkOption {
      type = lib.types.enum [
        "VANILLA"
        "GAPPS"
      ];
      default = "VANILLA";
      description = ''
        Which Android image to fetch on first boot. Apps come from Aurora Store,
        which needs no Google account or Play Services. GAPPS is there for an
        app that refuses to run without Play Services.
      '';
    };

    kioskUser = lib.mkOption {
      type = lib.types.str;
      default = "tv";
      description = "Account allowed to open Android apps.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.waydroid = {
      enable = true;
      # The default package uses legacy iptables, whose kernel module NixOS no
      # longer ships, so the Android session dies setting up its network.
      package = pkgs.waydroid-nftables;
    };

    environment.systemPackages = [ android-launch ];

    # Who may ask is decided by the socket's group, so the session never holds
    # root itself, not even for one command.
    users.groups.android-launch = { };
    users.users.${cfg.kioskUser}.extraGroups = [ "android-launch" ];

    systemd.sockets.android-launch = {
      description = "Requests to open Android apps";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = socketPath;
        SocketUser = "root";
        SocketGroup = "android-launch";
        SocketMode = "0660";
        Accept = true;
        MaxConnections = 4;
      };
    };
    systemd.services."android-launch@" = {
      description = "Open an Android app";
      serviceConfig = {
        ExecStart = lib.getExe android-launch-handler;
        StandardInput = "socket";
        # The handler writes its one-line answer here and logs to stderr.
        StandardOutput = "socket";
        StandardError = "journal";
        # Long enough for Android to finish booting, as the handler waits for it.
        RuntimeMaxSec = 120;
        NoNewPrivileges = true;
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        RestrictSUIDSGID = true;
      };
    };

    # The images are about a gigabyte and live outside the Nix store, so they
    # are fetched once on the first boot with a network, then left alone.
    systemd.services.waydroid-init = {
      description = "Fetch the Waydroid Android images";
      wantedBy = [ "multi-user.target" ];
      before = [ "waydroid-container.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathExists = "!/var/lib/waydroid/waydroid.cfg";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe waydroid} init -s ${cfg.imageType}";
        ExecStartPost = "${set-window-mode}";
      };
    };

    # Installing needs Android up, which needs the kiosk's display, so this
    # waits for as long as that takes. It runs on every boot but acts only once.
    systemd.services.waydroid-store = {
      description = "Install Aurora Store in Android";
      wantedBy = [ "multi-user.target" ];
      after = [ "waydroid-container.service" ];
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        waydroid
      ];
      script = ''
        until [ "$(waydroid shell -- getprop sys.boot_completed 2>/dev/null)" = 1 ]; do
          sleep 5
        done
        if ! waydroid shell -- pm list packages com.aurora.store | grep -q aurora; then
          waydroid shell -- pm install -S "$(stat -c %s ${aurora-store})" < ${aurora-store}
        fi
        # The two it requires, granted so its setup has nothing to answer.
        waydroid shell -- appops set com.aurora.store REQUEST_INSTALL_PACKAGES allow
        waydroid shell -- appops set com.aurora.store MANAGE_EXTERNAL_STORAGE allow
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "infinity";
      };
    };

    # Android takes most of a minute to boot, so it boots with the session rather
    # than when someone picks an app. Not before Plasma's shell is up, though:
    # until then its notification server does not answer, and Waydroid crashes
    # after giving up on it.
    systemd.user.services.waydroid-session = {
      description = "Android session";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [
        "graphical-session.target"
        "plasma-plasmashell.service"
      ];
      # Every account's user manager reads this unit; only the kiosk's gets a
      # running Android, the others would pay a minute of CPU for nothing.
      unitConfig.ConditionUser = cfg.kioskUser;
      environment.WAYLAND_DISPLAY = "wayland-0";
      # A failure can only be retried, as the TV has nobody to reset it.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        # On first boot the kiosk gets a display long before the images arrive.
        ExecStartPre = pkgs.writeShellScript "waydroid-wait-for-container" ''
          until ${pkgs.systemd}/bin/systemctl is-active --quiet waydroid-container; do
            ${pkgs.coreutils}/bin/sleep 5
          done
        '';
        TimeoutStartSec = "infinity";
        ExecStart = "${lib.getExe waydroid} session start";
        ExecStop = "${lib.getExe waydroid} session stop";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
  };
}
