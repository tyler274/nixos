{ config, lib, pkgs, inputs, ... }:

# Coda CI in disposable Firecracker guests (README: "Coda CI in Firecracker").
#
# The controller (coda_ci.py) runs from a timer. Each pass takes one job: a
# queued GitHub job labelled cyrene-coda, else the oldest local act request
# in spool/requests. The guest (coda-ci-guest.nix) gets a reflink clone of
# the seed work disk, a read-only inputs disk and the fc-coda-ci tap, whose
# traffic reaches only the internet.
let
  cfg = config.services.coda-ci;
  inherit (import ./zfs/lib.nix { inherit lib; }) agentsPoolCreated;
  root = "/agents/coda/ci";
  tap = "fc-coda-ci";
  hostAddress = "10.234.0.1/30";

  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      inputs.microvm.nixosModules.microvm
      ./coda-ci-guest.nix
      cfg.guest
    ];
  };
  guestMem = guest.config.microvm.mem;

  controller = pkgs.writeShellApplication {
    name = "coda-ci-controller";
    runtimeInputs = with pkgs; [ python3 coreutils e2fsprogs ];
    text = ''exec python3 ${./coda_ci.py} "$@"'';
  };

  cli = pkgs.writeShellApplication {
    name = "coda-ci";
    runtimeInputs = with pkgs; [ git coreutils ];
    text = builtins.readFile ./coda-ci.sh;
  };

  serviceConfig = {
    Type = "oneshot";
    User = "coda-ci";
    Group = "coda-ci";
    LoadCredential = lib.optional (cfg.tokenFile != null) "github-token:${cfg.tokenFile}";
    TimeoutStartSec = "3h15m";
    KillMode = "control-group";
    UMask = "0077";
    # The guest's memory is the Firecracker process's own.
    MemoryMax = "${toString (guestMem + 2048)}M";
    MemorySwapMax = 0;
    CPUQuota = "800%";
    Nice = 10;
    TasksMax = 512;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    CapabilityBoundingSet = "";
    ReadWritePaths = [ root ];
    InaccessiblePaths = [ "-/nix/var/nix/daemon-socket" "-/run/docker.sock" "-/var/lib/agent-secrets" ];
    DevicePolicy = "closed";
    DeviceAllow = [ "/dev/kvm rw" "/dev/net/tun rw" ];
    # The controller itself talks only to GitHub; the guest's traffic goes
    # through the tap and the nftables table below, not through this cgroup.
    IPAddressDeny = cfg.controllerAddressDeny;
    ExecStartPre = [ "+${tapUp}" ];
  };

  tapUp = pkgs.writeShellScript "coda-ci-tap" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.iproute2 ]}
    ip link show ${tap} >/dev/null 2>&1 || ip tuntap add ${tap} mode tap user coda-ci
    ip addr replace ${hostAddress} dev ${tap}
    ip link set ${tap} up
  '';

  environment = {
    CODA_CI_ROOT = root;
    CODA_CI_RUNNER = "${guest.config.microvm.declaredRunner}/bin/microvm-run";
    CODA_CI_GUEST_MEM_MIB = toString guestMem;
    CODA_CI_MARGIN_MIB = toString cfg.marginMiB;
    CODA_CI_WORK_DISK_SIZE = cfg.workDiskSize;
  } // lib.optionalAttrs (cfg.apiUrl != null) { CODA_CI_API = cfg.apiUrl; };

  blockedIPv4 = import ../../modules/nixos/blocked-ipv4.nix;
in
{
  options.services.coda-ci = {
    enable = lib.mkEnableOption "Coda CI jobs in disposable Firecracker guests";
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/coda-ci/github-token";
      description = ''
        Root-only file with a fine-grained token for Coda-Health/coda-rust
        (Administration: write, Actions: read). Without it only local act
        requests run.
      '';
    };
    guest = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      description = "Extra configuration for the guest (size, offline seed images).";
    };
    workDiskSize = lib.mkOption {
      type = lib.types.str;
      default = "200G";
      description = "Apparent size of the sparse seed work disk (Docker images, job scratch).";
    };
    marginMiB = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Memory that must stay available beside the guest before a job starts.";
    };
    apiUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "GitHub API base URL; only the VM test changes it.";
    };
    controllerAddressDeny = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "localhost" "link-local" "multicast" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
        "100.64.0.0/10" "0.0.0.0/8" "240.0.0.0/4"
      ];
    };
  };

  config = lib.mkMerge [
    # The spool exists with the pool, so the agent and the host CLI can queue
    # requests even while the controller is disabled.
    (lib.mkIf agentsPoolCreated {
      users.groups.coda-ci = { };
      users.users.coda-ci = {
        isSystemUser = true;
        group = "coda-ci";
        extraGroups = [ "kvm" ];
      };
      environment.systemPackages = [ cli ];

      # requests: anyone may drop a file but not list or remove others';
      # results: readable by all, written only by the controller.
      systemd.services.coda-ci-spool = {
        description = "Create the Coda CI spool on the agents pool";
        wantedBy = [ "multi-user.target" ];
        requires = [ "agents-pool.service" ];
        after = [ "agents-pool.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0755 -o coda-ci -g coda-ci ${root} ${root}/spool ${root}/spool/results ${root}/seed
          install -d -m 1733 -o coda-ci -g coda-ci ${root}/spool/requests
        '';
      };
    })

    (lib.mkIf cfg.enable {
      assertions = [{
        assertion = agentsPoolCreated;
        message = "services.coda-ci needs the agents pool (agentsPoolCreated in zfs/lib.nix).";
      }];

      networking.nat = {
        enable = true;
        internalInterfaces = [ tap ];
      };
      # Docker's iptables rules set the FORWARD policy to drop.
      virtualisation.docker.daemon.settings = lib.mkIf config.virtualisation.docker.enable {
        ip-forward-no-drop = true;
      };
      networking.nftables.tables.coda-ci = {
        family = "inet";
        content = ''
          set blocked4 {
            type ipv4_addr; flags interval;
            elements = { ${lib.concatStringsSep ", " blockedIPv4} }
          }

          chain forward {
            type filter hook forward priority filter - 10; policy accept;
            iifname "${tap}" meta nfproto ipv6 drop
            iifname "${tap}" ip daddr @blocked4 drop
            oifname "${tap}" ct state established,related accept
            oifname "${tap}" drop
          }

          chain input {
            type filter hook input priority filter - 10; policy accept;
            iifname "${tap}" ct state established,related accept
            iifname "${tap}" drop
          }
        '';
      };

      systemd.services.coda-ci = {
        description = "Run one Coda CI job in a disposable Firecracker guest";
        requires = [ "agents-pool.service" "coda-ci-spool.service" "nftables.service" ];
        bindsTo = [ "nftables.service" ];
        after = [ "agents-pool.service" "coda-ci-spool.service" "nftables.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        inherit environment;
        serviceConfig = serviceConfig // {
          ExecStart = lib.getExe controller;
        };
      };
      systemd.timers.coda-ci = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitInactiveSec = "15s";
        };
      };

      # Started by hand from main: sudo systemctl start coda-ci-seed
      systemd.services.coda-ci-seed = {
        description = "Build a fresh Coda CI seed work disk";
        requires = [ "agents-pool.service" "coda-ci-spool.service" "nftables.service" ];
        bindsTo = [ "nftables.service" ];
        after = [ "agents-pool.service" "coda-ci-spool.service" "nftables.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        inherit environment;
        serviceConfig = serviceConfig // {
          ExecStart = "${lib.getExe controller} seed";
        };
      };
    })
  ];
}
