# Evaluation-only checks on the HTPC's assembled configuration: facts that no
# VM test boots but that must hold together -- Home Player is on, it reads its
# secrets from the file `just secrets` installs, only the grown-up's account
# runs the kiosk, and the disk and boot chain can be unlocked from across the
# room on a box with no screen. Any false value throws, naming the claim.
{
  pkgs,
  config,
  options,
  extendModules,
}:
let
  inherit (pkgs) lib;
  hm = config.home-manager.users;
  cryptroot = config.boot.initrd.luks.devices.cryptroot or { };
  crypttabOpts = cryptroot.crypttabExtraOpts or [ ];
  # Newer nixpkgs removed the scripted initrd: the option stays declared, but
  # invisible, and reading it throws. The initrd is systemd either way.
  scriptedInitrdExists = options.boot.initrd.systemd.enable.visible or true;
  initrdIsSystemd = if scriptedInitrdExists then config.boot.initrd.systemd.enable else true;
  initrdSsh = config.boot.initrd.network.ssh;
  snapshots = config.services.sanoid.datasets;
  # A week of dailies and a day of hourlies and nothing older: sanoid's built-in
  # defaults would quietly add months of them to a 256 GB disk.
  keepsDayAndWeek =
    name:
    (snapshots.${name} or { }) ? hourly
    &&
      lib.getAttrs [ "autosnap" "autoprune" "hourly" "daily" "monthly" "yearly" ] snapshots.${name} == {
        autosnap = true;
        autoprune = true;
        hourly = 24;
        daily = 7;
        monthly = 0;
        yearly = 0;
      };
  fleetKey = builtins.head config.users.users.default-user.openssh.authorizedKeys.keys;
  zfsModule = config.boot.kernelPackages.${config.boot.zfs.package.kernelModuleAttribute};
  # The same machine with its night wake moved past the activation window.
  lateWake =
    (extendModules {
      modules = [ { roles.night-updates.wakeTime = lib.mkForce "06:00"; } ];
    }).config;
  failingAssertions = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  claims = {
    "the backend is enabled" = config.services.home-player.enable;
    "the backend reads secrets from /var/lib/home-player-secrets/env" =
      toString config.services.home-player.environmentFile == "/var/lib/home-player-secrets/env";
    "Wake-on-LAN is armed" = config.services.home-player.wakeOnLan.enable;
    "Android runs for vuxna" = config.roles.android.kioskUser == "vuxna";
    "the box wakes itself at 03:30" =
      config.systemd.timers.htpc-night.timerConfig.OnCalendar == "*-*-* 03:30:00"
      && config.systemd.timers.htpc-night.timerConfig.WakeSystem;
    "Plasma leaves suspending to Home Player, on any power profile" =
      let
        rc = config.environment.etc."xdg/powerdevilrc".text;
      in
      builtins.all (p: lib.hasInfix "[${p}][SuspendAndShutdown]\nAutoSuspendAction=0\n" rc) [
        "AC"
        "Battery"
        "LowBattery"
      ];
    "the night wake is inside the activation window" = failingAssertions config == [ ];
    "a night wake outside the activation window does not evaluate" =
      builtins.any (lib.hasInfix "wakeTime (06:00) must lie inside") (failingAssertions lateWake);
    "nixhost's cache is a substituter" =
      builtins.elem "http://nixhost.edholm.cc:8080" config.nix.settings.substituters;
    "cache.nixos.org is still a substituter" =
      builtins.elem "https://cache.nixos.org/" config.nix.settings.substituters;
    "the login screen hides the machine accounts" =
      config.services.displayManager.sddm.settings.Users.HideUsers or null == "default-user,deploy";
    "the update watchdog checks vuxna's kiosk" = config.roles.staged-updates.kioskUser == "vuxna";
    "a rollback is triggered by an unhealthy backend" = config.roles.staged-updates.requireHealthy;
    "vuxna has the kiosk shell" = hm ? vuxna && hm.vuxna.systemd.user.services ? home-player-shell;
    "barn has no kiosk shell" = !(hm ? barn);
    "Home Assistant drives the TV" =
      config.services.home-player.settings.home_assistant.tv == "media_player.android_tv_2";
    "Home Assistant drives the receiver" =
      config.services.home-player.settings.home_assistant.receiver == "media_player.marantz_sr6009";
    "Android only starts for vuxna" =
      config.systemd.user.services.waydroid-session.unitConfig.ConditionUser or null == "vuxna";

    "the disk is named by its stable id" =
      config.disko.devices.disk.main.device
      == "/dev/disk/by-id/nvme-SK_hynix_BC511_HFM256GDJTNI-82A0A_CY05N062410305M16";
    "cryptroot opens the partition the install steps name" =
      cryptroot.device or null == "/dev/disk/by-partlabel/disk-main-luks";
    "the install secret is read at format time from the agreed path" =
      config.disko.devices.disk.main.content.partitions.luks.content.passwordFile or null
      == "/tmp/htpc-luks.key";
    "the unlock tries the TPM" = builtins.elem "tpm2-device=auto" crypttabOpts;
    "the unlock measures the volume key into PCR 15" =
      builtins.elem "tpm2-measure-pcr=yes" crypttabOpts;
    "wrong passphrases never lock a headless box out of the prompt" =
      builtins.elem "tries=0" crypttabOpts;
    "TRIM reaches the disk through LUKS" = cryptroot.allowDiscards or false;
    "the initrd has what a TPM unlock needs" = config.boot.initrd.systemd.tpm2.enable;
    "the pool is not imported until the disk is unlocked" =
      builtins.elem "cryptsetup.target" config.boot.initrd.systemd.services.zfs-import-rpool.after;

    "the initrd runs systemd" = initrdIsSystemd;
    "Lanzaboote signs the boot" = config.boot.lanzaboote.enable or false;
    "Lanzaboote uses sbctl's key bundle" = config.boot.lanzaboote.pkiBundle or null == "/var/lib/sbctl";
    "the first install works before any key exists" = config.boot.lanzaboote.allowUnsigned or false;
    "old generations cannot fill the 1 GiB ESP" = lib.elem (config.boot.lanzaboote.configurationLimit
      or null
    ) (lib.range 2 5);
    "systemd-boot is out of the way" = !config.boot.loader.systemd-boot.enable;
    "sbctl is installed" = builtins.any (p: lib.getName p == "sbctl") config.environment.systemPackages;

    "the initrd has the NIC's driver" =
      builtins.elem "e1000e" config.boot.initrd.availableKernelModules;
    "the initrd brings the network up" = config.boot.initrd.network.enable;
    # With no fixed machine-id, the initrd's default client ID differs on every
    # boot, and DHCP then sees a new client each time.
    "the initrd asks DHCP as the same client on every boot" =
      config.boot.initrd.systemd.network.networks."99-ethernet-default-dhcp".dhcpV4Config.ClientIdentifier
        or null == "mac";
    "the installed system asks DHCP as that same client" =
      lib.hasInfix "clientid" config.networking.dhcpcd.extraConfig;
    "initrd SSH is on" = initrdSsh.enable;
    "initrd SSH is on port 2222" = initrdSsh.port == 2222;
    "initrd SSH admits the fleet key" = builtins.elem fleetKey initrdSsh.authorizedKeys;
    # A string, not a Nix path: a path would be read at evaluation, which fails
    # on the laptop, or worse copy the private key into the store.
    "the initrd host key stays off the store" =
      initrdSsh.hostKeys == [ "/etc/secrets/initrd/ssh_host_ed25519_key" ]
      && builtins.isString (builtins.head initrdSsh.hostKeys);
    "the initrd host key is appended by the boot loader installer" =
      config.boot.loader.supportsInitrdSecrets;

    "the ZFS cache is capped at 1 GiB" =
      builtins.elem "zfs.zfs_arc_max=1073741824" config.boot.kernelParams;
    "zram is on" = config.zramSwap.enable;
    "firmware blobs are available" = config.hardware.enableRedistributableFirmware;
    "the kernel is the default LTS" =
      config.boot.kernelPackages.kernel.version == pkgs.linuxPackages.kernel.version;
    "ZFS supports the kernel" = !zfsModule.meta.broken;

    "snapshots are taken" = config.services.sanoid.enable;
    "only home and var are snapshotted" =
      builtins.attrNames snapshots == [
        "rpool/home"
        "rpool/var"
      ];
    "home keeps a day of hourlies and a week of dailies" = keepsDayAndWeek "rpool/home";
    "var keeps a day of hourlies and a week of dailies" = keepsDayAndWeek "rpool/var";
  };
  failed = builtins.attrNames (lib.filterAttrs (_: ok: ok != true) claims);
in
assert lib.assertMsg (failed == [ ]) "htpc-eval: false: ${builtins.concatStringsSep "; " failed}";
pkgs.runCommand "htpc-eval" { } "touch $out"
