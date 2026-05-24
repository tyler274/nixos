{
  description = "Multi-host NixOS flake (Cyrene, nixos-wsl, Laptop) with Home Manager as the primary user surface";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-staging.url = "github:nixos/nixpkgs/staging";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
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
