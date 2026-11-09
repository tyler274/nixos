{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  upstreamPkgs = import inputs.nixpkgs {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  # nixpkgs' cargo-setup-hook forces system libs (AWS_LC_SYS_USE_SYSTEM=1,
  # zstd, ...), but codex's aws-lc-sys 0.45.0 finds no usable system AWS-LC
  # (only openssl's headers). Build the bundled C deps instead. Drop once
  # nixpkgs' codex builds again.
  codex = upstreamPkgs.codex.overrideAttrs { dontCargoUseSystemLibs = true; };
  host = {
    package = upstreamPkgs.callPackage ../../packages/orca-ide { };
    profile = "${config.xdg.dataHome}/orca-server";
    port = 6768;
  };
in
{
  home.packages = [
    host.package
    codex
    upstreamPkgs.claude-code
    (pkgs.writeShellScriptBin "orca-server" ''
      export ORCA_USER_DATA_PATH=${lib.escapeShellArg host.profile}
      exec ${host.package}/bin/orca-ide "$@"
    '')
  ];

  systemd.user.services.orca-serve = {
    Unit = {
      Description = "Orca agent server";
      StartLimitIntervalSec = 900;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "simple";
      ExecStart = "${host.package}/bin/orca-ide serve --supervise --no-pairing --port ${toString host.port}";
      Environment = [
        "ORCA_USER_DATA_PATH=${host.profile}"
        "PATH=${lib.makeBinPath [ codex upstreamPkgs.claude-code ]}:${config.home.profileDirectory}/bin:${config.home.homeDirectory}/.nix-profile/bin:${config.home.homeDirectory}/.local/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStopSec = 90;
      # The AppImage's bwrap is the main PID. Stop its server children too;
      # Orca's persistent terminal daemon lives in a separate user scope.
      KillMode = "control-group";
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
