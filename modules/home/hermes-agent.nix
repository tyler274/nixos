{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

# Hermes Agent (github:NousResearch/hermes-agent) - agent orchestration as a
# per-user service. Upstream recommends the Home Manager module over the
# NixOS one for a personal machine: credentials, memory, sessions and cron
# jobs all belong to one person, so it runs as luluco with state in
# ~/.hermes rather than as a separate `hermes` system user.
#
# Needs `users.users.luluco.linger = true` (set in hosts/cyrene/default.nix),
# otherwise systemd stops the user units at logout.
#
# Secrets: this repo has no sops-nix/agenix, so the OpenRouter key lives in
# an untracked file that activation merges into ~/.hermes/.env:
#
#   install -Dm600 /dev/stdin ~/.config/hermes/env <<< 'OPENROUTER_API_KEY=sk-or-...'
#   systemctl --user restart hermes-agent hermes-backend
#
# A missing file is only a warning during activation, so the rebuild works
# before the key is in place.
#
# CLI config commands (`hermes setup`, `hermes config set`, ...) are blocked
# in managed mode; change `settings` here and rebuild instead. Keys Hermes
# itself adds to config.yaml at runtime are preserved across rebuilds.
#
# Verify: systemctl --user status hermes-agent hermes-backend
#         journalctl --user -u hermes-agent -f
#         hermes config
{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  # `hermes` CLI on PATH + HERMES_HOME exported, so the shell shares state
  # (sessions, skills, cron) with the services.
  programs.hermes-agent = {
    enable = true;
    desktop.enable = true;
  };

  services.hermes-agent = {
    enable = true;

    # Long-running gateway: runs cron jobs and scheduled agent work. No
    # messaging platform is configured yet; it keeps running for cron.
    gateway.enable = true;

    # `hermes dashboard` on 127.0.0.1:9119: web admin panel plus the
    # /api/ws + /api/pty sockets. Loopback only, so no auth gate needed.
    backend = {
      mode = "dashboard";
      port = 9119;
    };

    settings = {
      # No base_url => OpenRouter (Hermes' default provider).
      model.default = "anthropic/claude-opus-4.6";
      toolsets = [ "all" ];
      terminal = {
        backend = "local";
        timeout = 180;
      };
      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };
      compression = {
        enabled = true;
        threshold = 0.85;
      };
    };

    environmentFiles = [ "${config.xdg.configHome}/hermes/env" ];

    # Same NixOS package/option search server Cursor uses (.cursor/mcp.json).
    mcpServers.nixos.command = lib.getExe pkgs.mcp-nixos;
  };
}
