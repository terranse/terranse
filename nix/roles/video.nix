# Hardware video decode and audio out. `driver` is an enum rather than a free
# string so a typo fails at evaluation with the valid values listed, instead
# of silently deploying a box with no VA-API.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.video;
in
{
  options.roles.video = {
    enable = lib.mkEnableOption "hardware video acceleration and audio output";

    driver = lib.mkOption {
      type = lib.types.enum [ "intel" ];
      description = ''
        Which GPU stack to install. No default on purpose: a machine that
        enables this role must say which hardware it has.
      '';
      example = "intel";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf (cfg.driver == "intel") {
        hardware.graphics = {
          enable = true;
          extraPackages = with pkgs; [
            # 9th-gen iGPU (UHD 630): iHD decodes up to HEVC and VP9, with no AV1
            # block. A box of 11th gen or newer also wants vpl-gpu-rt.
            intel-media-driver
          ];
        };
        # WebKitGTK picks its VA-API driver from the environment, and gets it
        # wrong on Intel without this.
        environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
        environment.systemPackages = [ pkgs.libva-utils ];
      })

      {
        services.pulseaudio.enable = false;
        security.rtkit.enable = true;
        services.pipewire = {
          enable = true;
          alsa.enable = true;
          alsa.support32Bit = true;
          pulse.enable = true;
        };
      }
    ]
  );
}
