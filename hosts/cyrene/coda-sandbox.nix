{ lib, inputs, ... }:

# Cyrene's Coda agent sandbox. The module, its options and its docs live in
# coda-rust's crates/workspace-tools/sandbox flake (input coda-sandbox; its
# README.md there).
let
  inherit (import ./zfs/lib.nix { inherit lib; }) agentsPoolCreated;
in
{
  imports = [ inputs.coda-sandbox.nixosModules.default ];

  services.coda-sandbox = {
    # The sandbox lives on the agents pool (zfs/agents.nix).
    enable = agentsPoolCreated;
    user = "luluco";
    requires = [ "agents-pool.service" ];
    uidBase = 655360;
    hostAddress = "10.233.1.1";
    localAddress = "10.233.1.2";
    memoryMax = "24G";
    memoryHigh = "20G";
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBeBvlXnNHWV5nhvbyvTG0xe+41dxNtX9l/QRPDqOD8s coda-agent"
    ];
    ci = {
      enable = true;
      tokenFile = "/var/lib/coda-ci/github-token";
    };
  };
}
