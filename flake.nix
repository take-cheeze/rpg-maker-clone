{
  inputs = {
    # Fetched from the NixOS channel mirror (*.nixos.org) rather than
    # `github:nixos/nixpkgs` so the flake resolves in sandboxes whose GitHub
    # access is scoped to the session's own repositories (e.g. Claude Code on
    # the web), where GitHub archive tarballs for other repos are rejected.
    # Channel revisions are what cache.nixos.org has prebuilt, so binary-cache
    # hit rates are as good as or better than tracking the release branch head.
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";
    self.submodules = true;
  };

  outputs =
    { self, nixpkgs }:
    let
      # Minimal inline of flake-utils' `eachDefaultSystem`, dropped as an input
      # for the same GitHub-scoping reason as nixpkgs above. For each system it
      # evaluates `f system` and lifts every returned attribute to
      # `<attr>.<system>`, merging across systems.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachDefaultSystem =
        f:
        builtins.foldl' (
          acc: system:
          let
            ret = f system;
          in
          builtins.foldl' (
            acc': key: acc' // { ${key} = (acc'.${key} or { }) // { ${system} = ret.${key}; }; }
          ) acc (builtins.attrNames ret)
        ) { } systems;
    in
    eachDefaultSystem (
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
                ccache
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
                # Python is used by the repo's tooling scripts (the MV
                # corescript build and scripts/serve.py). It has been
                # reaching them transitively through other inputs;
                # name it so a required CI step cannot lose it.
                python3
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
              )
              # Software-GL environment for the MZ WebGL backend's headless EGL
              # (mruby-mvjs/src/mvgl.cxx). This setup hook, shipped by nixpkgs
              # mesa, exports LIBGL_ALWAYS_SOFTWARE / LIBGL_DRIVERS_PATH /
              # __EGL_VENDOR_LIBRARY_FILENAMES / LD_LIBRARY_PATH pointing at
              # mesa's llvmpipe + glvnd EGL vendor, so the surfaceless EGL
              # context finds a driver on a plain (non-NixOS) CI runner and
              # MV::GL.smoke_test runs. Linux-only, like the backend itself.
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.mesa.llvmpipeHook
              ];
            cp932_table = pkgs.fetchurl {
              url = "https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit932.txt";
              hash = "sha256-JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE=";
            };
            jis0208_table = pkgs.fetchurl {
              url = "https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT";
              hash = "sha256-HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc=";
            };
            buildInputs =
              (with pkgs; [
                SDL2
                SDL2_mixer
              ])
              # EGL + GLES2 back the RPG Maker MZ WebGL renderer
              # (mruby-mvjs/src/mvgl.cxx, ADR 0004 M6.3). libglvnd supplies the
              # <EGL/egl.h> / <GLES2/gl2.h> headers and the libEGL / libGLESv2
              # dispatch libraries; the actual off-screen driver (llvmpipe, via
              # the surfaceless EGL platform) comes from mesa, discovered at run
              # time through mesa.llvmpipeHook below. With the headers present
              # mvgl.cxx's __has_include guard compiles the real backend (rather
              # than the inert stubs used on Emscripten's browser WebGL), and
              # MV::GL.smoke_test renders its green triangle in CI instead of
              # skipping. Linux-only: this targets the headless CI/dev runner,
              # and mvgl stubs itself where the headers are absent (e.g. darwin).
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.libglvnd
              ];
            # The package build only builds; tests are run separately via CTest.
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
        };
        devShell = self.packages.${system}.build.overrideAttrs {
          CMAKE_C_COMPILER_LAUNCHER = "${pkgs.sccache}/bin/sccache";
          CMAKE_CXX_COMPILER_LAUNCHER = "${pkgs.sccache}/bin/sccache";
        };
      }
    );
}
