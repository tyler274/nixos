{
  description = "NixOS configuration";  
  
  inputs = {
    #nixpkgs.url = "github:nixos/nixpkgs/release-22.11";
    nixpkgs-stable.url = "github:nixos/nixpkgs/release-22.11";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };  
  
  outputs = { self, nixpkgs, nixpkgs-stable, ... }: 
    let
      system = "x86_64-linux";
      overlay-stable = final: prev: {
        #unstable = nixpkgs-unstable.legacyPackages.${prev.system};
        # use this variant if unfree packages are needed:
         stable = import nixpkgs-stable {
           inherit system;
           config.allowUnfree = true;
         };

      };
    in {
    nixosConfigurations = {
      Sulla = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          # Overlays-module makes "pkgs.unstable" available in configuration.nix
          ({ config, pkgs, ... }: { nixpkgs.overlays = [ overlay-stable ]; })
          ./configuration.nix
        ];
      };
    };
  };
  
}
