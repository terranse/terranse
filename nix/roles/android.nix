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
  # the app has drawn its first frame, "ok" for home, or "failed <reason>",
  # always within 28 s of the request so the client is still there to hear it.
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
      # Children get fd 3 closed, so none of them can hold the client waiting.
      exec 3>&1 1>&2
      reply() { echo "$1" >&3 || true; }

      pkg=""
      read -r -t 5 -n 256 pkg || [ -n "$pkg" ] || exit 2

      # Every answer must be written within this, as the client waits 30 s.
      # The 2 s kept back cover the grace `timeout -k` gives a stuck command.
      SECONDS=0
      budget=28
      left() { echo $((budget - 2 - SECONDS)); }

      # Android's Home takes the app's window away and hands the screen back.
      if [ "$pkg" = home ]; then
        timeout -k 2 10 waydroid shell -- input keyevent KEYCODE_HOME 3>&-
        reply ok
        exit 0
      fi

      if ! [[ "$pkg" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]; then
        echo "android-launch: refused a request that is not a package name"
        exit 2
      fi

      # Android freezes when idle, and may still be booting right after login.
      # Waiting for it takes from the same budget. Each `waydroid shell` costs
      # about a second, so the boot check and the lookup share one.
      # An app with an Android TV interface lists it under LEANBACK_LAUNCHER,
      # next to its phone one: that is the one to open on a TV (SVT Play has
      # both). Without one, the ordinary entry.
      timeout -k 2 5 waydroid container unfreeze 3>&- || true
      while :; do
        if [ "$(left)" -le 1 ]; then
          reply "failed boot-timeout"
          exit 1
        fi
        resolved=$(timeout -k 2 "$(left)" waydroid shell -- sh -c "[ \"\$(getprop sys.boot_completed)\" = 1 ] \
          && echo booted && for category in LEANBACK_LAUNCHER LAUNCHER; do \
          cmd package resolve-activity --brief -a android.intent.action.MAIN \
          -c android.intent.category.\$category $pkg | tail -n 1 | grep / && break; done" \
          2>/dev/null 3>&- | tr -d '\r') || true
        [[ "$resolved" == booted* ]] && break
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
      # exits 0 whatever happened, so the answer is read from its output. It
      # gets whatever is left of the budget to draw.
      if [ "$(left)" -le 0 ]; then
        reply "failed draw-timeout"
        exit 1
      fi
      rc=0
      out=$(timeout -k 2 "$(left)" waydroid shell -- sh -c "setprop waydroid.active_apps home-player; \
        am start -W --windowingMode 1 -n '$component'" 2>&1 3>&-) || rc=$?
      echo "$out"
      case "$out" in
        *"Status: ok"*) reply ready ;;
        *)
          # 124 when it ran out of time, 137 when it then had to be killed.
          if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
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
  # knows when to show it. Longer than the handler's 28 s budget.
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

  # Android writes an icon for each app into the kiosk's home, which the Home
  # Player backend cannot read, so they are copied somewhere it can. The kiosk
  # can write there, so the files are read with its rights and never through a
  # link, and only package-named PNGs are taken.
  iconSource = "${config.users.users.${cfg.kioskUser}.home}/.local/share/waydroid/data/icons";
  iconTarget = "/var/lib/waydroid-icons";
  entrySource = "${config.users.users.${cfg.kioskUser}.home}/.local/share/applications";
  export-icons = pkgs.writeShellApplication {
    name = "waydroid-export-icons";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.util-linux
    ];
    text = ''
      # Android writes them all at once, so let it finish first.
      sleep 2
      shopt -s nullglob
      for icon in ${iconSource}/*.png; do
        name=''${icon##*/}
        [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+\.png$ ]] || continue
        if [ -L "$icon" ] || ! [ -f "$icon" ]; then continue; fi
        copy=$(mktemp -p ${iconTarget})
        # A swapped-in pipe would block the read forever, hence the timeout.
        if timeout 5 setpriv --reuid=${cfg.kioskUser} --regid=${
          config.users.users.${cfg.kioskUser}.group
        } --clear-groups \
          dd if="$icon" iflag=nofollow bs=1M count=1 status=none >"$copy"; then
          chmod 0644 "$copy"
          mv -f "$copy" "${iconTarget}/$name"
        else
          rm -f "$copy"
        fi
      done
      # An app that is gone leaves no icon behind.
      for icon in ${iconTarget}/*.png; do
        [ -e "${iconSource}/''${icon##*/}" ] || rm -f "$icon"
      done

      # Every app Android lists in its launcher, as "package<TAB>name" lines,
      # so the TV can show an app as soon as it is installed. Waydroid writes
      # one desktop entry per app; its Name is the app's own. Read the same
      # careful way as the icons.
      list=$(mktemp -p ${iconTarget})
      for entry in ${entrySource}/waydroid.*.desktop; do
        package=''${entry##*/waydroid.}
        package=''${package%.desktop}
        [[ "$package" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || continue
        if [ -L "$entry" ] || ! [ -f "$entry" ]; then continue; fi
        title=$(timeout 5 setpriv --reuid=${cfg.kioskUser} --regid=${
          config.users.users.${cfg.kioskUser}.group
        } --clear-groups \
          dd if="$entry" iflag=nofollow bs=64k count=1 status=none \
          | sed -n '/^Name=/{s///p;q}' | tr -d '\t\r' | cut -c 1-80) || continue
        [ -n "$title" ] && printf '%s\t%s\n' "$package" "$title" >>"$list"
      done
      chmod 0644 "$list"
      mv -f "$list" ${iconTarget}/apps.tsv
    '';
  };

  # Runs with every start of the container, once Android has booted. Each step
  # was found by hand on the HTPC on 2026-11-20.
  kioskManager = "${cfg.kioskUser}@";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  tv-setup = pkgs.writeShellApplication {
    name = "waydroid-tv-setup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
      waydroid
    ];
    text = ''
      # A frozen container never answers `waydroid shell`.
      ashell() {
        timeout -k 2 5 waydroid container unfreeze || true
        timeout -k 2 30 waydroid shell -- "$@" | tr -d '\r'
      }

      until [ "$(ashell getprop sys.boot_completed 2>/dev/null)" = 1 ]; do
        sleep 5
      done

      # Restarting the container ends this service too (it is part of it), and
      # its next start runs these checks again. Twice in a row at most, so a
      # cause a restart cannot cure is not retried forever; a clean pass resets
      # the count.
      restarts=/run/waydroid-tv-setup/restarts
      mkdir -p "''${restarts%/*}"
      restart_android() {
        local count
        count=$(cat "$restarts" 2>/dev/null || echo 0)
        if [ "$count" -ge 2 ]; then
          echo "waydroid-tv-setup: $1, but Android was already restarted twice; leaving it be"
          return 1
        fi
        echo $((count + 1)) >"$restarts"
        echo "waydroid-tv-setup: $1; restarting Android"
        # In a unit of its own, as restarting the container stops this one.
        systemd-run --no-block --collect --unit=waydroid-tv-restart \
          --description="Restart Android for the TV set-up" \
          ${pkgs.runtimeShell} -c "${systemctl} --user -M ${kioskManager} stop waydroid-session.service; \
            ${systemctl} restart waydroid-container.service; \
            ${systemctl} --user -M ${kioskManager} start waydroid-session.service"
        exit 0
      }

      # Android's system server can crash in its media code seconds after boot.
      # It comes back, but its network stack does not: Android then never asks
      # for an address and stays offline until the container restarts. Seen on
      # the HTPC on 2026-11-20, and likely the "lost DNS" of 2026-11-05.
      online=""
      for _ in $(seq 30); do
        if ashell ip -4 addr show eth0 2>/dev/null | grep -q inet; then
          online=yes
          break
        fi
        sleep 2
      done
      [ -n "$online" ] || restart_android "Android has no network address" || true

      # Waydroid's separate windows put the display in desktop mode, where
      # every app gets an 84 px title bar across its top. Fullscreen mode drops
      # the bar, and each app still gets its own window that closes when it is
      # left. Read only at boot, so a change costs one restart. Density 320 is
      # a 1080p Android TV's: 180 (Waydroid's guess) makes TV interfaces tiny.
      settings=/data/system/display_settings.xml
      display=$(ashell sh -c "abx2xml $settings - 2>/dev/null" | grep '<display ' || true)
      if ! [[ "$display" == *'forcedDensity="320"'* && "$display" == *'windowingMode="1"'* ]]; then
        ashell wm density 320 >/dev/null
        ashell sh -c "abx2xml $settings - \
          | sed -e 's/ windowingMode=\"[0-9]*\"//' -e 's/forcedDensity=\"320\"/& windowingMode=\"1\"/' \
          >/data/local/tmp/display_settings.xml \
          && xml2abx /data/local/tmp/display_settings.xml $settings \
          && chown system:system $settings && chmod 600 $settings \
          && rm /data/local/tmp/display_settings.xml"
        restart_android "set the display to fullscreen mode" || true
      fi

      # Android's media volume at most: the receiver sets how loud it is.
      ashell cmd media_session volume --stream 3 --set 15 >/dev/null
      rm -f "$restarts"
    '';
  };

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

    # Android rewrites the icons each time its session starts. The copy at
    # boot covers a session that never starts.
    systemd.paths.waydroid-icons = {
      description = "Watch for new Android app icons";
      wantedBy = [ "paths.target" ];
      pathConfig.PathChanged = iconSource;
    };
    systemd.services.waydroid-icons = {
      description = "Copy Android app icons where the TV interface can read them";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = 60;
        ExecStart = lib.getExe export-icons;
        StateDirectory = "waydroid-icons";
        StateDirectoryMode = "0755";
        UMask = "0022";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        PrivateNetwork = true;
        NoNewPrivileges = true;
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

    # Part of the container, so every start of it (a boot, or a restart this
    # very service asks for) runs it again.
    systemd.services.waydroid-tv-setup = {
      description = "Set Android up for the TV, and restart it if it came up offline";
      wantedBy = [ "waydroid-container.service" ];
      after = [ "waydroid-container.service" ];
      partOf = [ "waydroid-container.service" ];
      serviceConfig = {
        ExecStart = lib.getExe tv-setup;
        # Not a oneshot: until the kiosk logs in Android does not boot, and a
        # oneshot would hold up the container's start for as long.
        Type = "exec";
        RemainAfterExit = true;
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
      # Not a oneshot: while Android is not up, a oneshot would hold
      # multi-user.target, and everything ordered after it (the power profile
      # daemon among them) would wait as long.
      serviceConfig = {
        Type = "exec";
        RemainAfterExit = true;
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
      # The compositor's socket name is whatever KWin got (wayland-1 on the
      # HTPC on 2026-11-06), and Plasma hands it to the user manager; a name
      # fixed here left Android unable to start for a whole evening.
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
