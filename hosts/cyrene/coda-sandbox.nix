{
  config,
  lib,
  inputs,
  ...
}:

# Cyrene's Coda agent sandbox. The module, its options and its docs live in
# coda-rust's crates/workspace-tools/sandbox flake (input coda-sandbox; its
# README.md there).
let
  inherit (import ./zfs/lib.nix { inherit lib; }) agentsPoolCreated;
in
{
  imports = [
    inputs.coda-sandbox.nixosModules.default
    inputs.ungate.nixosModules.default
  ];

  # The model proxy: holds the Claude and ChatGPT sign-ins and records usage
  # per client key. Cursor's extension adopts it on its port; the container
  # reaches it on hostAddress with the broker's model-proxy key. Its admin
  # routes answer only on loopback.
  services.ungate = {
    enable = agentsPoolCreated;
    hosts = [
      "127.0.0.1"
      "10.233.1.1"
    ];
  };

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
    # The controller's GitHub token is `github-ci` in luluco's keyring,
    # served by the token broker.
    ci.enable = true;
    # Claude Code and Codex in the container go through ungate above; the
    # key is `model-proxy` in luluco's keyring.
    container.modelProxy = {
      enable = true;
      port = config.services.ungate.port;
    };
    # Swarm workers on local models reach Ollama (modules/nixos/ollama.nix)
    # at http://10.233.1.1:11434.
    container.hostTcpPorts = [ config.services.ollama.port ];
  };

  # Ollama takes one listen address and 10.233.1.1 exists only while the
  # container runs, so it listens on every IPv4 address. The host firewall
  # opens the port on the container's veth alone, not to the LAN or Tailscale.
  services.ollama.host = lib.mkIf agentsPoolCreated "0.0.0.0";
}
