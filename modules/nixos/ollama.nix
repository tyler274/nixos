# Ollama 0.30.5 from nixpkgs-staging. The pinned nixos-unstable tarball still
# ships 0.24.0; staging/master carry v0.30.5. Overlay only the ollama
# variants so the rest of the system stays on the primary nixpkgs tree.
# Drop this module once pkgs.ollama-cuda.version ≥ 0.30.5 on nixpkgs.

{ config, inputs, pkgs, ... }:

let
  inherit (config.nixpkgs.hostPlatform) system;
in
{
 # nixpkgs.overlays = [
 #   (final: prev: let
 #     stagingPkgs = import inputs.nixpkgs-staging {
 #       inherit system;
 #       config = prev.config;
 #     };
 #   in {
 #     inherit (stagingPkgs) ollama ollama-cuda ollama-cpu ollama-rocm ollama-vulkan;
 #   })
 # ];

  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
  };

  services.nextjs-ollama-llm-ui.enable = true;
}
