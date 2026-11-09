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
    # Hermes Agent's main model (modules/home/hermes-agent.nix).
    loadModels = [ "qwen3.8:27b" ];
    # Hermes needs a 64K window. Its per-request options.num_ctx is ignored
    # on Ollama's OpenAI-compatible /v1 route, which otherwise serves 32K.
    environmentVariables.OLLAMA_CONTEXT_LENGTH = "65536";
  };

  services.nextjs-ollama-llm-ui.enable = true;
}
