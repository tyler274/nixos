# mcp-nixos depends on fastmcp 3.4.7, whose fastmcp-slim is marked
# `broken = versionAtLeast mcp.version "2"`: python3Packages.mcp is now 2.x
# and renamed `mcp.shared.exceptions.McpError` -> `MCPError`, so fastmcp
# fails to import. nixpkgs still ships mcp 1.x as `mcp_1`; rebuild only
# mcp-nixos's Python set against it so the rest of the system keeps mcp 2.
#
# Remove once nixpkgs fastmcp supports mcp 2 (fastmcp-slim no longer broken).
final: prev:
let
  python3 = prev.python3.override {
    self = python3;
    packageOverrides = pyfinal: _: { mcp = pyfinal.mcp_1; };
  };
in
{
  mcp-nixos = prev.mcp-nixos.override { python3Packages = python3.pkgs; };
}
