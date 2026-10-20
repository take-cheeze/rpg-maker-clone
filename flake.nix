{
  inputs = {
    # Fetched from the NixOS channel mirror (*.nixos.org) rather than
    # `github:nixos/nixpkgs` so the flake resolves in sandboxes whose GitHub
    # access is scoped to the session's own repositories (e.g. Claude Code on
    # the web). Channel revisions are what cache.nixos.org has prebuilt, so
    # binary-cache hit rates are as good as tracking the release branch head.
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";
  };

  # `self.submodules = true` deliberately *not* set here. It made every `nix`
  # call fetch all twelve submodules with `refs/*:refs/*` -- a full-history
  # fetch per submodule, lvgl alone being ~760 MiB of refs -- and only
  # `packages.build` ever reads those sources. The dev shell does not: every job
  # that enters it (`build`, `ruby-checks`, `wasm`) compiles the checkout in
  # $GITHUB_WORKSPACE, not nix's copy of it, so the walk was pure latency there.
  # The one consumer that needs them asks per command instead:
  #
  #     nix build '.?submodules=1#build'
  #
  # See the `flake` job in .github/workflows/build.yml.

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
            # bison and gperf regenerate vendored mruby's own compiler
            # (mrbgems/mruby-compiler/core/{parse.y,keywords} ->
            # y.tab.c/lex.def) whenever a 3rd/mruby patch touches either
            # source -- a no-op on an ordinary build, since the checked-in
            # generated files are already newer, but load-bearing the moment
            # one does (patches/mruby-defined-keyword.patch, the first to).
            nativeBuildInputs =
              with pkgs;
              [
                autoconf
                automake
                bison
                ccache
                cmake
                cmake-format
                emscripten
                git
                gperf
                lhasa
                libXi
                mold
                ninja
                nixfmt
                pre-commit
                ruby_4_0
                sccache
                unar
                wget
                xvfb
                xvfb-run
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
            RUBY_YJIT_ENABLE = "1";
            LOCALE_ARCHIVE =
              if system == "x86_64-linux" then "${pkgs.glibcLocales}/lib/locale/locale-archive" else null;
            shellHook = ''
              export CTEST_PARALLEL_LEVEL=$NIX_BUILD_CORES
            '';
          };
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # The Android SDK + NDK the Gradle build (app/android) compiles
          # against, assembled by nixpkgs' androidenv from its pinned,
          # hash-checked copies of Google's repository XML -- the same
          # components the CI android job installs by hand through
          # sdkmanager ("ndk;27.2.12479018", "cmake;3.22.1" on the runner's
          # preinstalled SDK) and the manual ~/android-sdk the README used to
          # ask for. Versions mirror app/android/app/build.gradle's own pins:
          # ndkVersion "27.2.12479018", compileSdk 34 (AGP 8.5.2's default
          # build-tools 34.0.0) and externalNativeBuild's cmake "3.22.1".
          # androidenv lays the NDK out at ndk/<version> and cmake at
          # cmake/<version> under the SDK root, exactly where AGP's
          # ndkVersion/cmake version lookups expect them, and the accepted
          # licenses are baked in so Gradle never stops on an unaccepted
          # agreement.
          android-sdk =
            let
              # composeAndroidPackages takes license acceptance from the
              # nixpkgs *config* (androidenv's license.nix), not from its own
              # arguments, so this composition gets a pkgs instance of its own
              # with android_sdk.accept_license set -- the licenses are baked
              # into the SDK tree it produces, and Gradle never stops on an
              # unaccepted agreement. The SDK components are themselves unfree
              # (Google's SDK terms), so allowUnfree rides along. Both are
              # scoped to this import: the flake's other outputs keep the
              # stock config.
              androidPkgs = import nixpkgs {
                localSystem = system;
                config = {
                  android_sdk.accept_license = true;
                  allowUnfree = true;
                };
              };
            in
            # composeAndroidPackages returns an attrset of components; the
            # flake packages output wants one derivation, so take the
            # assembled SDK root (the `androidsdk` member -- cmdline-tools.nix's
            # symlink farm with platforms/, build-tools/, ndk/<version>/,
            # cmake/<version>/ and the accepted licenses).
            (androidPkgs.androidenv.composeAndroidPackages {
              platformVersions = [ "34" ];
              buildToolsVersions = [ "34.0.0" ];
              includeNDK = true;
              ndkVersions = [ "27.2.12479018" ];
              cmakeVersions = [ "3.22.1" ];
              includeEmulator = false;
              includeSources = false;
              includeSystemImages = false;
            }).androidsdk;
        }
      );

      # `devShells.default`, the current flake schema's spelling of what used to
      # be the singular `devShell` output. The compiler launcher is dev-only:
      # the sandboxed package build has no sccache to hit.
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sccache = "${pkgs.sccache}/bin/sccache";
        in
        {
          default = self.packages.${system}.build.overrideAttrs (old: {
            CMAKE_C_COMPILER_LAUNCHER = sccache;
            CMAKE_CXX_COMPILER_LAUNCHER = sccache;
            # wine is a shell-only dependency, kept out of `packages.build`
            # above: nothing in the package build runs a Windows binary, so
            # putting it there only made `nix build '.#build'` (the `flake` CI
            # job) realise a 32-bit wine closure it never opens. It is still
            # load-bearing for the shell — `scripts/rtp/install.bash` /
            # `rtp_xp_install.bash` install the RPG Maker 2000/XP RTPs by
            # running the vendors' own installers under wine, and the engine
            # then resolves the RTP through that prefix's registry
            # (`rtp_path()` / `xp_rtp_path()` in src/main.cxx) — so the `build`
            # CI job, which enters the shell, keeps it. `winetricks` is gone
            # entirely: nothing in the tree ever called it.
            nativeBuildInputs =
              old.nativeBuildInputs
              ++ pkgs.lib.optionals (system == "x86_64-linux") [
                pkgs.winePackages.staging
                pkgs.winePackages.fonts
              ];
            # `.envrc`'s `layout python3` puts the project venv's bin/ ahead of
            # everything else on PATH, so the venv's `python3` -- a symlink into
            # this flake's nix store closure -- is what any `#!/usr/bin/env
            # python3` script resolves to for the lifetime of the shell. That
            # interpreter's loader is nix's own glibc (a hardcoded nix-store
            # path, not /lib64/ld-linux-x86-64.so.2), which never reads the
            # host distro's ld.so.cache or /usr/lib -- only its own RPATH
            # closure and LD_LIBRARY_PATH. Binary wheels pulled into the venv
            # with plain pip (numpy, which piper-tts depends on) expect the
            # host's libstdc++/libz to be reachable the normal FHS way and
            # fail with "cannot open shared object file" without them, as does
            # any *other* `env python3` script picked up while cd'd into this
            # directory (e.g. the system's /opt/rocm `amd-smi`, which needs
            # libstdc++ the same way). Exporting these two nix-store lib dirs
            # on LD_LIBRARY_PATH covers both cases without touching the host
            # system.
            shellHook = old.shellHook + ''
              export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.zlib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            '';
          });

          # Only host tools used by the closed-world bc2cpp gate.
          bc2cpp = pkgs.mkShell {
            packages = with pkgs; [
              ruby_4_0
              gcc
              clang
              bison
              gperf
              git
              curl
              python3
              pkg-config
            ];
          };

          # libclang and its Python bindings, for scripts/native/binding_facts.py
          # (ADR 0263): `nix develop .#clang -c ruby scripts/native/binding_split.rb check`.
          # Kept out of the default shell so nothing else pays for the LLVM
          # closure. The script also needs 3rd/ and a built mruby include
          # directory (RGSS_MRUBY_BUILD_DIR, default build/mruby/host).
          clang = pkgs.mkShell {
            packages = [
              pkgs.ruby_4_0
              (pkgs.python3.withPackages (ps: [ ps.libclang ]))
            ];
            LIBCLANG_FILE = "${pkgs.llvmPackages.libclang.lib}/lib/libclang.so";
            RUBY_YJIT_ENABLE = "1";
          };

          # The Android build shell: the base build environment (cmake/ninja/
          # ruby/gperf/bison, the Unicode mapping tables) plus the SDK+NDK
          # composition above and a JDK for Gradle, wired through the
          # environment variables AGP and gradlew actually read -- ANDROID_HOME
          # for the SDK root (AGP finds ndk/<version> and cmake/<version>
          # inside it itself), ANDROID_NDK_HOME for anything that wants the NDK
          # directly, JAVA_HOME so ./gradlew runs on this JDK instead of
          # prompting a toolchain download. Gradle itself stays the wrapper
          # (gradlew pins the distribution; first run fetches it).
          #
          # Linux-only: CI builds the APK on ubuntu, and
          # that is the configuration this composition is pinned and tested
          # against. On darwin use the default devshell plus a hand-installed
          # SDK (app/android/README.md keeps the manual recipe).
          android = nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
            self.packages.${system}.build.overrideAttrs (old: {
              nativeBuildInputs = old.nativeBuildInputs ++ [
                self.packages.${system}.android-sdk
                pkgs.jdk21
              ];
              # The SDK root is the derivation's libexec/android-sdk tree
              # (deployAndroidPackage's layout) -- that is where platforms/,
              # build-tools/, ndk/<version>/ and cmake/<version>/ live, and
              # what AGP walks for its ndkVersion / cmake version lookups.
              ANDROID_HOME = "${self.packages.${system}.android-sdk}/libexec/android-sdk";
              ANDROID_NDK_HOME = "${self.packages.${system}.android-sdk}/libexec/android-sdk/ndk/27.2.12479018";
              JAVA_HOME = "${pkgs.jdk21.home}";
              shellHook = old.shellHook + ''
                echo "android shell: ANDROID_HOME=$ANDROID_HOME"
                java -version 2>&1 | head -1
                echo "build:    (cd app/android && ./gradlew :app:assembleDebug)"
                echo "install:  adb install -r app/android/app/build/outputs/apk/debug/app-debug.apk"
              '';
            })
          );
        }
      );
    };
}
