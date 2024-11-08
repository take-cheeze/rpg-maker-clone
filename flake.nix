{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          packages = rec {
            build = pkgs.stdenv.mkDerivation {
              name = "rpg-maker-clone";
              srcs = [
                ./.
              ];
              nativeBuildInputs = with pkgs; [
                ninja
                cmake
                ruby
                ccache
              ];
              buildInputs = with pkgs; [
                SDL2
              ];
              CMAKE_CXX_COMPILER_LAUNCHER = "ccache";
              CMAKE_BUILD_TYPE = "RelWithDebInfo";
              CTEST_OUTPUT_ON_FAILURE = "1";
              shellHook = ''
                export CTEST_PARALLEL_LEVEL=$NIX_BUILD_CORES
              '';
            };
            default = build;
          };
        }
      );
}
