{
  description = "NixOS configuration";  
  
  inputs = {
    #nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/release-22.11";
    nixpkgs-staging.url = "github:nixos/nixpkgs/staging";
    nixpkgs.url = "github:nixos/nixpkgs/master";
  };  
  
  outputs = { self, nixpkgs, nixpkgs-stable, nixpkgs-unstable, nixpkgs-staging, ... }: 
    let
      system = "x86_64-linux";
      overlay-stable-unstable-pkgs = final: prev: {
        #unstable = nixpkgs-unstable.legacyPackages.${prev.system};
        # use this variant if unfree packages are needed:
         stable-pkgs = import nixpkgs-stable {
           inherit system;
           config.allowUnfree = true;
         };
         unstable-pkgs = import nixpkgs-unstable {
           inherit system;
           config.allowUnfree = true;
         };
         staging-pkgs = import nixpkgs-staging {
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
          ({ config, pkgs, ... }: { nixpkgs.overlays = [ overlay-stable-unstable-pkgs ]; })
          ./configuration.nix
        ];
      };
    };
  };
  
}
