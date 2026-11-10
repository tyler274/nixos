{
  config,
  lib,
  pkgs,
  ...
}:

# Hardened NixOS containers for coding agents and CI jobs.
#
# Each sandbox is a systemd-nspawn container with:
#   * its own user namespace at a fixed host UID base, so container root and
#     the `agent` user are unmapped high UIDs on the host. The base is fixed
#     (not "pick") because the host Nix daemon admits the agent by its host
#     UID, which must be stable across restarts.
#   * plain (not idmapped) read-write binds: files the agent writes show the
#     container's host UID, so host tools such as git treat them as foreign.
#   * a private network with a veth pair and NAT; host nftables drops its
#     traffic to private, CGNAT (Tailscale), link-local and multicast ranges
#     and every connection it opens to the host itself.
#   * cgroup limits on the container unit.
#
# Starting a sandbox never gates boot: units it needs are `requires`, the
# container is only wanted by machines.target, and a failure stays local.
let
  cfg = config.agentSandbox;
  agentUid = 1000;
  usersGid = 100;

  blockedIPv4 = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.168.0.0/16"
    "198.18.0.0/15"
    "224.0.0.0/4"
    "240.0.0.0/4"
  ];

  sandboxOptions =
    { name, ... }:
    {
      options = {
        uidBase = lib.mkOption {
          type = lib.types.ints.u32;
          description = "First host UID of the container's 65536-UID range; a multiple of 65536.";
        };
        hostAddress = lib.mkOption { type = lib.types.str; };
        localAddress = lib.mkOption { type = lib.types.str; };
        autoStart = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        ephemeral = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Give the container a fresh root on every start.";
        };
        binds = lib.mkOption {
          description = "Host directories bound into the container, keyed by container path.";
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                hostPath = lib.mkOption { type = lib.types.str; };
                readOnly = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                };
                ownedByAgent = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Create the host directory owned by the container's agent UID.";
                };
              };
            }
          );
        };
        requires = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Units the container needs; it fails to start without them.";
        };
        authorizedKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        memoryMax = lib.mkOption {
          type = lib.types.str;
          default = "24G";
        };
        memoryHigh = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Throttle point below memoryMax; defaults to memoryMax.";
        };
        cpuQuota = lib.mkOption {
          type = lib.types.str;
          default = "1600%";
        };
        tasksMax = lib.mkOption {
          type = lib.types.int;
          default = 8192;
        };
        config = lib.mkOption {
          type = lib.types.deferredModule;
          default = { };
          description = "Extra NixOS configuration for the container.";
        };
      };
    };

  hostAgentUid = s: s.uidBase + agentUid;
  hostAgentGid = s: s.uidBase + usersGid;
  iface = name: "ve-${name}";

  containerModule =
    name: s:
    { pkgs, ... }:
    {
      imports = [ s.config ];
      system.stateVersion = "26.05";

      networking.useHostResolvConf = false;
      services.resolved.enable = false;
      networking.nameservers = [
        "1.1.1.1"
        "9.9.9.9"
      ];
      networking.firewall.enable = true;
      networking.firewall.allowedTCPPorts = lib.optional (s.authorizedKeys != [ ]) 22;

      users.mutableUsers = false;
      # Root is reached only from the host (machinectl / nixos-container run).
      users.allowNoPasswordLogin = true;
      users.users.agent = {
        isNormalUser = true;
        uid = agentUid;
        group = "users";
        openssh.authorizedKeys.keys = s.authorizedKeys;
      };
      security.sudo.enable = false;

      services.openssh = lib.mkIf (s.authorizedKeys != [ ]) {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
          AllowUsers = [ "agent" ];
          AllowAgentForwarding = false;
          X11Forwarding = false;
          # Remote-SSH tunnels to its server on the container's loopback.
          AllowTcpForwarding = "local";
        };
      };

      # The Cursor remote server and other prebuilt binaries.
      programs.nix-ld.enable = true;

      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      environment.systemPackages = with pkgs; [
        git
        gh
        curl
        jq
      ];
    };
in
{
  options.agentSandbox = {
    containers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule sandboxOptions);
      default = { };
    };
  };

  config = lib.mkIf (cfg.containers != { }) {
    assertions = lib.mapAttrsToList (name: s: {
      assertion = lib.mod s.uidBase 65536 == 0 && s.uidBase >= 65536;
      message = "agentSandbox.containers.${name}.uidBase must be a non-zero multiple of 65536";
    }) cfg.containers;

    containers = lib.mapAttrs (name: s: {
      inherit (s)
        autoStart
        ephemeral
        hostAddress
        localAddress
        ;
      privateNetwork = true;
      privateUsers = s.uidBase;
      # Shift the container's own root tree into its range once.
      extraFlags = [ "--private-users-ownership=auto" ];
      restartIfChanged = false;
      bindMounts = lib.mapAttrs (_: b: {
        inherit (b) hostPath;
        isReadOnly = b.readOnly;
      }) s.binds;
      config = containerModule name s;
    }) cfg.containers;

    systemd.services = lib.mapAttrs' (
      name: s:
      lib.nameValuePair "container@${name}" {
        requires = s.requires;
        after = s.requires;
        preStart = lib.mkBefore (
          lib.concatStrings (
            lib.mapAttrsToList (
              _: b:
              lib.optionalString b.ownedByAgent ''
                install -d -m 0750 -o ${toString (hostAgentUid s)} -g ${toString (hostAgentGid s)} ${lib.escapeShellArg b.hostPath}
              ''
            ) s.binds
          )
        );
        serviceConfig = {
          MemoryMax = s.memoryMax;
          MemoryHigh = if s.memoryHigh != null then s.memoryHigh else s.memoryMax;
          CPUQuota = s.cpuQuota;
          TasksMax = s.tasksMax;
        };
      }
    ) cfg.containers;

    # The host daemon sees each container's agent by host UID, which
    # nss-mymachines names vu-<container>-<uid>; the daemon matches the name
    # when one resolves and the number otherwise. Admit exactly the agents.
    # Builds still run as nixbld users, and the agents are not trusted.
    nix.settings.allowed-users = lib.concatLists (
      lib.mapAttrsToList (name: s: [
        "vu-${name}-${toString agentUid}"
        (toString (hostAgentUid s))
      ]) cfg.containers
    );

    networking.nat = {
      enable = true;
      internalInterfaces = lib.mapAttrsToList (name: _: iface name) cfg.containers;
    };

    # Docker's iptables rules set the FORWARD policy to drop, which would also
    # drop the sandboxes' NAT traffic. Docker filters its own bridges anyway.
    virtualisation.docker.daemon.settings = lib.mkIf config.virtualisation.docker.enable {
      ip-forward-no-drop = true;
    };

    networking.nftables.tables.agent-sandbox = {
      family = "inet";
      content =
        let
          ifaces = lib.concatMapStringsSep ", " (n: ''"${iface n}"'') (lib.attrNames cfg.containers);
        in
        ''
          set blocked4 {
            type ipv4_addr; flags interval;
            elements = { ${lib.concatStringsSep ", " blockedIPv4} }
          }

          chain forward {
            type filter hook forward priority filter - 10; policy accept;
            iifname { ${ifaces} } meta nfproto ipv6 drop
            iifname { ${ifaces} } ip daddr @blocked4 drop
            oifname { ${ifaces} } ct state established,related accept
            oifname { ${ifaces} } drop
          }

          chain input {
            type filter hook input priority filter - 10; policy accept;
            iifname { ${ifaces} } ct state established,related accept
            iifname { ${ifaces} } drop
          }
        '';
    };
  };
}
