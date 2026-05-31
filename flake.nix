{
  description = "Multi-host NixOS flake (Cyrene, nixos-wsl, Laptop) with Home Manager as the primary user surface";

  inputs = {
    nixpkgs.url = "git+https://github.com/nixos/nixpkgs.git?ref=nixos-unstable&shallow=1";
    nixpkgs-stable.url = "git+https://github.com/nixos/nixpkgs.git?ref=nixos-26.05&shallow=1";
    nixpkgs-staging.url = "git+https://github.com/nixos/nixpkgs.git?ref=staging&shallow=1";
    nixos-hardware.url = "git+https://github.com/NixOS/nixos-hardware.git?ref=master&shallow=1";
    nixos-wsl = {
      url = "git+https://github.com/nix-community/NixOS-WSL.git?ref=main&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "git+https://github.com/nix-community/home-manager.git?ref=release-26.05&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "git+https://github.com/nix-community/lanzaboote.git?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Enables a certain anime game launcher
    aagl = {
      aagl.url = "github:ezKEa/aagl-gtk-on-nix";
      # Or, if you follow Nixkgs release 25.05:
      # aagl.url = "github:ezKEa/aagl-gtk-on-nix/release-25.05";
      aagl.inputs.nixpkgs.follows = "nixpkgs"; # Name of nixpkgs input you want to use
    };
  };

  outputs =
    { self
    , nixpkgs
    , nixpkgs-stable
    , nixpkgs-staging
    , nixos-hardware
    , nixos-wsl
    , home-manager
    , lanzaboote
    , ...
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

      mkHost = hostPath: extraModules: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ({ ... }: { nixpkgs.overlays = [ pkgsOverlay ]; })
          home-manager.nixosModules.home-manager
          hostPath
        ] ++ extraModules;
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
        ];
      };
    };
}
