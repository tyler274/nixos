{ pkgs, ... }:
let
  scratch = "/nix/var/nix/builds/coda";
  cache = "/var/cache/coda-encrypted";
  storage = pkgs.writeShellApplication {
    name = "coda-storage";
    runtimeInputs = with pkgs; [ coreutils util-linux cryptsetup e2fsprogs systemd ];
    text = builtins.readFile ./coda-storage.sh;
  };
in
{
  environment.systemPackages = [ storage ];

  environment.etc."coda/build-profile.json".text = builtins.toJSON {
    version = 1;
    user = "luluco";
    scratch_root = "${scratch}/local";
    cache_root = "${cache}/local";
    cache_size = "100G";
    mounts = [
      { path = "/nix/var/nix/builds"; source = "/dev/mapper/scratch"; }
      { path = cache; source = "/dev/mapper/coda-cache"; }
    ];
  };

  systemd.mounts = [{
    what = "/dev/mapper/coda-cache";
    where = cache;
    type = "ext4";
    options = "nodev,nosuid,noatime";
    unitConfig.RequiresMountsFor = "/var/cache/ccache";
  }];

  systemd.services.coda-scratch-directories = {
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = "/nix/var/nix/builds";
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    path = with pkgs; [ coreutils util-linux ];
    script = ''
      test "$(findmnt -rn -M /nix/var/nix/builds -o SOURCE)" = /dev/mapper/scratch
      install -d -m 0711 -o root -g root ${scratch}
      install -d -m 0700 -o luluco -g users ${scratch}/local
      install -d -m 0700 -o root -g root ${scratch}/ci
    '';
  };

  systemd.services.coda-cache-directories = {
    bindsTo = [ "var-cache-coda\\x2dencrypted.mount" ];
    after = [ "var-cache-coda\\x2dencrypted.mount" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    path = with pkgs; [ coreutils util-linux ];
    script = ''
      test "$(findmnt -rn -M ${cache} -o SOURCE)" = /dev/mapper/coda-cache
      chmod 0711 ${cache}
      install -d -m 0700 -o luluco -g users ${cache}/local
      install -d -m 0700 -o root -g root ${cache}/ci
    '';
  };
}
