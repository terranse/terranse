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

  # Needs root because it reaches into the container, so it gets one sudo entry
  # and refuses anything that isn't a package name.
  android-start = pkgs.writeShellApplication {
    name = "android-start";
    runtimeInputs = [
      pkgs.coreutils
      waydroid
    ];
    text = ''
      # Android's Home takes the app's window away and hands the screen back.
      if [ "''${1:-}" = --home ]; then
        waydroid shell -- input keyevent KEYCODE_HOME
        exit 0
      fi

      pkg="''${1:-}"
      if ! [[ "$pkg" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]; then
        echo "android-start: '$pkg' is not a package name" >&2
        exit 2
      fi

      # Android freezes when idle, and may still be booting right after login.
      waydroid container unfreeze || true
      for _ in $(seq 1 60); do
        [ "$(waydroid shell -- getprop sys.boot_completed 2>/dev/null)" = 1 ] && break
        sleep 1
      done

      component=$(waydroid shell -- cmd package resolve-activity --brief \
        -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$pkg" \
        | tail -n 1 | tr -d '\r')
      case "$component" in
        */*) ;;
        *)
          echo "android-start: $pkg is not installed" >&2
          exit 1
          ;;
      esac

      # `waydroid app launch` can only open a small floating window, so start
      # the activity directly in fullscreen mode. The window then shows only
      # while this property names something other than the app, and an app it
      # does name stays invisible, hence the neutral value.
      waydroid shell -- setprop waydroid.active_apps home-player
      waydroid shell -- settings put global policy_control 'immersive.full=*'
      waydroid shell -- am start --windowingMode 1 -n "$component"
    '';
  };

  android-launch = pkgs.writeShellScriptBin "android-launch" ''
    exec /run/wrappers/bin/sudo -n ${lib.getExe android-start} "$@"
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

    security.sudo.extraRules = [
      {
        users = [ cfg.kioskUser ];
        commands = [
          {
            command = lib.getExe android-start;
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

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

    # Android takes most of a minute to boot, so it boots as soon as the kiosk
    # has a display rather than when someone picks an app.
    systemd.user.paths.waydroid-session = {
      description = "Start Android when the kiosk has a display";
      wantedBy = [ "default.target" ];
      pathConfig.PathExists = "%t/wayland-0";
    };
    systemd.user.services.waydroid-session = {
      description = "Android session";
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
