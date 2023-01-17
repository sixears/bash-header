{
  description = "Standardized Bash Header";

  inputs = {
    nixpkgs.url     = github:nixos/nixpkgs/3ae365af; # 2023-01-14
    flake-utils.url = github:numtide/flake-utils/c0e246b9;
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      rec {
        packages.bash-header =
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
            import ./header.nix { inherit pkgs; };

        defaultPackage = packages.bash-header;
      });
}
