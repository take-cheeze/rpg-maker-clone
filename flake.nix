{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=release-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages = rec {
          build = pkgs.stdenv.mkDerivation {
            name = "rpg-maker-clone";
            srcs = [ ./. ];
            nativeBuildInputs =
              with pkgs;
              [
                autoconf
                automake
                cabal-install
                clang-tools
                cmake
                cmake-format
                emscripten
                ghc
                git
                libXi
                mold
                ninja
                nixfmt
                pre-commit
                ruby
                sccache
                unar
                wget
                xvfb
                xvfb-run
              ]
              ++ (
                if system == "x86_64-linux" then
                  with pkgs;
                  [
                    winePackages.staging
                    winePackages.fonts
                    winetricks
                  ]
                else
                  [ ]
              );
            cp932_table = pkgs.fetchurl {
              url = "https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit932.txt";
              hash = "sha256-JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE=";
            };
            jis0208_table = pkgs.fetchurl {
              url = "https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT";
              hash = "sha256-HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc=";
            };
            buildInputs = with pkgs; [ SDL2 ];
            # The package build only builds; tests are run separately via CTest.
            # Prevents nixpkgs' pytest check hook from hijacking the check phase
            # (it collects no tests and fails with exit code 5).
            doCheck = false;
            dontUsePytestCheck = true;
            CMAKE_BUILD_TYPE = "RelWithDebInfo";
            CTEST_OUTPUT_ON_FAILURE = "1";
            GLOG_logtostderr = "1";
            LOCALE_ARCHIVE =
              if system == "x86_64-linux" then "${pkgs.glibcLocales}/lib/locale/locale-archive" else null;
            shellHook = ''
              export CTEST_PARALLEL_LEVEL=$NIX_BUILD_CORES
            '';
          };
        };
        devShell = self.packages.${system}.build.overrideAttrs {
          CMAKE_C_COMPILER_LAUNCHER = "${pkgs.sccache}/bin/sccache";
          CMAKE_CXX_COMPILER_LAUNCHER = "${pkgs.sccache}/bin/sccache";
        };
      }
    );
}
