# macOS Home Manager for this Mac. User-facing only: the declarative
# mcp-nixos package from nixpkgs, and Cursor's MCP client config.
# Activate with:
#   nix run home-manager -- switch --flake ~/code/nixos#macbook

{ pkgs, ... }:

{
  home.username = "tyler";
  home.homeDirectory = "/Users/tyler";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  home.packages = [ pkgs.mcp-nixos ];

  # Cursor launches MCP servers from the GUI session, which does not source
  # the Nix profile. Bind the client at the store path of the package above.
  home.file.".cursor/mcp.json".text = ''
    {
      "mcpServers": {
        "nixos": {
          "command": "${pkgs.mcp-nixos}/bin/mcp-nixos"
        }
      }
    }
  '';

  # Fallback for the repo's .cursor/mcp.json, which cannot embed a
  # per-system store path.
  home.file.".local/bin/mcp-nixos".source = "${pkgs.mcp-nixos}/bin/mcp-nixos";
}
