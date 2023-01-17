{
  description = "Standardized Bash Header";

  inputs = {
    nixpkgs.url     = github:nixos/nixpkgs/3ae365af; # 2023-01-14
    flake-utils.url = github:numtide/flake-utils/c0e246b9;
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      rec {
        defaultPackage = packages.bash-header;

        packages.bash-header =
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          import ./header.nix { inherit pkgs; };
##            pkgs.writers.writeBashBin "my-script" ''
##              DATE="$(${pkgs.ddate}/bin/ddate +'the %e of %B%, %Y')"
##              ${pkgs.cowsay}/bin/cowsay Hello, world! Today is $DATE.
##            '';
      });

}
