{
  description = "Multi-host NixOS flake (Cyrene, nixos-wsl, Laptop) with Home Manager as the primary user surface";

  inputs = {
    nixpkgs.url = "git+https://github.com/nixos/nixpkgs.git?ref=nixos-unstable&shallow=1";
    nixpkgs-stable.url = "git+https://github.com/nixos/nixpkgs.git?ref=nixos-26.05&shallow=1";
    nixpkgs-staging.url = "git+https://github.com/nixos/nixpkgs.git?ref=staging&shallow=1";
    # Tracks K900's in-progress Plasma 6.7 (beta) work (nixpkgs PR #520160).
    # We overlay only `kdePackages` from this tree (see pkgsOverlay below) so
    # the rest of the system stays on the pinned nixos-unstable above. Plasma
    # 6.7 rewrote the DRM color-management pipeline, fixing the KWin login
    # segfault in DrmAbstractColorOp::matchPipeline on NVIDIA 610+.
    # Drop this input (and the overlay) once nixos-unstable carries 6.7.0.
    # nixpkgs-plasma.url = "git+https://github.com/K900/nixpkgs.git?ref=plasma-6.7&shallow=1";
    nixos-hardware.url = "git+https://github.com/NixOS/nixos-hardware.git?ref=master&shallow=1";
    nixos-wsl = {
      url = "git+https://github.com/nix-community/NixOS-WSL.git?ref=main&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "git+https://github.com/nix-community/home-manager.git?ref=master&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "git+https://github.com/nix-community/lanzaboote.git?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Enables a certain anime game launcher
    aagl = {
      url = "github:ezKEa/aagl-gtk-on-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    kwin-src = {
      url = "github:KDE/kwin/master";
      flake = false;
    };
    # Declarative KDE management
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # Mini Diarium — encrypted local-first journaling app. Points at the fork
    # branch that carries the flake; switch to "github:fjrevoredo/mini-diarium"
    # once the packaging PR is merged upstream.
    mini-diarium = {
      url = "github:tyler274/mini-diarium/nix-flake-packaging";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      nixpkgs-staging,
      nixos-hardware,
      nixos-wsl,
      home-manager,
      lanzaboote,
      plasma-manager,
      ...
    }@inputs:
    let
      system = "x86_64-linux";

      pkgsOverlay = final: prev: {
        stable-pkgs = import nixpkgs-stable {
          inherit system;
          config.allowUnfree = true;
        };
        staging-pkgs = import nixpkgs-staging {
          inherit system;
          config.allowUnfree = true;
        };
      };

      # Plasma 6.7 (beta): replace the entire `kdePackages` scope with the one
      # from the 6.7 branch. KF6 (6.26) and KDE Gear (26.04) are unchanged, so
      # only the Plasma set rebuilds. This is the real fix for the KWin DRM
      # color-pipeline crash; the nvidia-drm.color_pipeline=0 kernel param
      # remains as a defensive fallback.
      # plasma67Pkgs = import inputs.nixpkgs-plasma {
      #   inherit system;
      #   config.allowUnfree = true;
      # };
      # kdeOverlay = final: prev: {
      #   kdePackages = plasma67Pkgs.kdePackages;
      # };

      mkHost =
        hostPath: extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            # ({ ... }: { nixpkgs.overlays = [ pkgsOverlay kdeOverlay ]; })
            ({ ... }: { nixpkgs.overlays = [ pkgsOverlay ]; })
            home-manager.nixosModules.home-manager
            hostPath
          ]
          ++ extraModules;
        };
    in
    {
      nixosConfigurations = {
        Cyrene = mkHost ./hosts/cyrene [
          lanzaboote.nixosModules.lanzaboote
        ];

        CyreneMinimal = mkHost ./hosts/cyrene/minimal.nix [
          lanzaboote.nixosModules.lanzaboote
        ];

        eula = mkHost ./hosts/wsl [
          nixos-wsl.nixosModules.default
        ];

        Laptop = mkHost ./hosts/laptop [ ];
      };

      devShells.${system}.default = nixpkgs.legacyPackages.${system}.mkShell {
        packages = with nixpkgs.legacyPackages.${system}; [
          gptfdisk
          umount
          nixd
          nil
          nix-output-monitor
          nh
        ];
      };
    };
}
