{
  inputs = {
    # Fetched from the NixOS channel mirror (*.nixos.org) rather than
    # `github:nixos/nixpkgs` so the flake resolves in sandboxes whose GitHub
    # access is scoped to the session's own repositories (e.g. Claude Code on
    # the web). Channel revisions are what cache.nixos.org has prebuilt, so
    # binary-cache hit rates are as good as tracking the release branch head.
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";
    self.submodules = true;
  };

  outputs =
    { self, nixpkgs }:
    let
      # Stands in for flake-utils' `eachDefaultSystem`, dropped as an input for
      # the same GitHub-scoping reason as nixpkgs above.
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          build = pkgs.stdenv.mkDerivation {
            name = "rpg-maker-clone";
            srcs = [ ./. ];
            nativeBuildInputs =
              with pkgs;
              [
                autoconf
                automake
                ccache
                clang-tools
                cmake
                cmake-format
                emscripten
                git
                lhasa
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
              ++ lib.optionals (system == "x86_64-linux") [
                winePackages.staging
                winePackages.fonts
                winetricks
              ]
              # Software-GL environment for the MZ WebGL backend's headless EGL
              # (mruby-mvjs/src/mvgl.cxx). The setup hook exports LIBGL_* /
              # __EGL_VENDOR_LIBRARY_FILENAMES / LD_LIBRARY_PATH pointing at
              # mesa's llvmpipe + glvnd EGL vendor, so the surfaceless EGL
              # context finds a driver on a plain (non-NixOS) CI runner and
              # MV::GL.smoke_test runs. Linux-only, like the backend itself.
              ++ lib.optionals stdenv.hostPlatform.isLinux [ mesa.llvmpipeHook ];
            cp932_table = pkgs.fetchurl {
              url = "https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit932.txt";
              hash = "sha256-JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE=";
            };
            jis0208_table = pkgs.fetchurl {
              url = "https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT";
              hash = "sha256-HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc=";
            };
            buildInputs =
              with pkgs;
              [
                SDL2
                SDL2_mixer
              ]
              # libglvnd supplies the <EGL/egl.h> / <GLES2/gl2.h> headers and
              # the libEGL / libGLESv2 dispatch libraries the RPG Maker MZ
              # renderer needs (mruby-mvjs/src/mvgl.cxx, ADR 0004 M6.3); the
              # off-screen driver comes from mesa at run time via llvmpipeHook
              # above. With the headers present mvgl.cxx's __has_include guard
              # compiles the real backend instead of the inert stubs, so
              # MV::GL.smoke_test renders in CI rather than skipping.
              # Linux-only: mvgl stubs itself where the headers are absent.
              ++ lib.optionals stdenv.hostPlatform.isLinux [ libglvnd ];
            # The package build only builds; tests run separately via CTest.
            # Prevents nixpkgs' pytest check hook from hijacking the check phase
            # (it collects no tests and fails with exit code 5).
            doCheck = false;
            dontUsePytestCheck = true;
            CMAKE_BUILD_TYPE = "RelWithDebInfo";
            CMAKE_GENERATOR = "Ninja";
            CTEST_OUTPUT_ON_FAILURE = "1";
            GLOG_logtostderr = "1";
            LOCALE_ARCHIVE =
              if system == "x86_64-linux" then "${pkgs.glibcLocales}/lib/locale/locale-archive" else null;
            shellHook = ''
              export CTEST_PARALLEL_LEVEL=$NIX_BUILD_CORES
            '';
          };
        }
      );

      # `devShells.default`, the current flake schema's spelling of what used to
      # be the singular `devShell` output. The compiler launcher is dev-only:
      # the sandboxed package build has no sccache to hit.
      devShells = forAllSystems (
        system:
        let
          sccache = "${nixpkgs.legacyPackages.${system}.sccache}/bin/sccache";
        in
        {
          default = self.packages.${system}.build.overrideAttrs {
            CMAKE_C_COMPILER_LAUNCHER = sccache;
            CMAKE_CXX_COMPILER_LAUNCHER = sccache;
          };
        }
      );
    };
}
