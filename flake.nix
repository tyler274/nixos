{
  description = "NixOS configuration";  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-22.11";
  };  outputs = { nixpkgs, ... }: {
    nixosConfigurations = {
      Sulla = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
        ];
      };
    };
  };
}
