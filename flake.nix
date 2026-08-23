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
                ruby
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
            LOCALE_ARCHIVE =
              if system == "x86_64-linux" then "${pkgs.glibcLocales}/lib/locale/locale-archive" else null;
            shellHook = ''
              export CTEST_PARALLEL_LEVEL=$NIX_BUILD_CORES
            '';
          };
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # The pspdev cross-toolchain ($PSPDEV: psp-gcc/binutils/newlib/
          # pspsdk headers, psp-cmake and the CreatePBP.cmake plumbing app/psp's
          # CMakeLists.txt drives), packaged from upstream's own release tarball.
          # nixpkgs has no pspsdk/psptoolchain package (checked the pinned
          # channel), so this fills the gap rather than overriding one.
          #
          # Why the release tarball instead of building psptoolchain from
          # source: the toolchain is a chain of autotools cross-builds
          # (binutils -> gcc stage 1 -> newlib -> gcc stage 2) that takes hours
          # and has never been packaged for nix; upstream attaches a ready-made
          # x86_64-linux build to every GitHub release, and the toolchain turns
          # out to be fully relocatable -- psp-gcc compiles PSP ELFs straight
          # out of an extracted tarball wherever it sits, no baked-in
          # /usr/local/pspdev. autoPatchelfHook repoints the host tools'
          # interpreters/RPATHs at the nix closure (the bundled MIPS objects
          # are left alone; they are not x86_64 ELF).
          #
          # Version pinning matters beyond reproducibility here: the release
          # tag fixes which pspsdk commit ships, and scripts/'
          # build_psp_fixup_imports.bash + patches/'
          # psp-fixup-imports-jal-relocation-aware.patch pin the *same* commit
          # (314b2083, v20260801's "Add AMCTRL_OBJS to libpspkernel_a_LIBADD")
          # as the source the patched psp-fixup-imports below is compiled
          # from. Bump all three together, and re-check that the stock tool
          # the tarball ships still matches the patch's assumptions when you
          # do (the patch's preamble says how to tell).
          #
          # That patched tool replaces the tarball's stock psp-fixup-imports in
          # the same postInstall: app/psp/CMakeLists.txt refuses to configure
          # against the stock one (it misorders imports so several genuine
          # PSP module imports silently resolve wrong at runtime -- see the
          # patch preamble and ADR 0047's bug 11 trail), so a devshell whose
          # SDK still carried it would fail loudly anyway. Building it inside
          # this derivation (rather than asking the shell hook to run the
          # script) keeps the sandbox honest: no network fetch of pspsdk at
          # shell-entry time, the sources come from the fetchzip pin instead.
          pspdev =
            let
              version = "20260801";
              # The exact pspsdk commit the release tarball ships and the fixup
              # patch was written against (see above).
              pspsdkFixupSrc = pkgs.fetchzip {
                url = "https://github.com/pspdev/pspsdk/archive/314b2083f2e1eaf145fc5de342736336fe1f0148.tar.gz";
                hash = "sha256-fy/PBRvol6G3o9nNlm+TLtUIJze9Xt/G+D4xYy4G6MM=";
              };
            in
            pkgs.stdenv.mkDerivation {
              pname = "pspdev";
              inherit version;
              src = pkgs.fetchurl {
                url = "https://github.com/pspdev/pspdev/releases/download/v${version}/pspdev-ubuntu-latest-x86_64.tar.gz";
                hash = "sha256-emyy3iG/vB1KoG0Q0KRcVH3tyPbhyPx/+Me6bu5mfuY=";
              };
              sourceRoot = "pspdev";
              nativeBuildInputs = [ pkgs.autoPatchelfHook ];
              # Host-side shared objects the tarball's tools link against that
              # Ubuntu ships and a nix closure does not. zstd is the big one --
              # binutils and cc1/cc1plus are built with
              # --enable-compressed-debug-sections, so they all want
              # libzstd.so.1; gmp/mpfr/mpc are gcc's own arithmetic; xz/expat/
              # ncurses/readline/libusb are psp-gdb and the download tools.
              # (libarchive/curl/openssl/gpgme would only serve the bundled
              # pacman, which installPhase drops.)
              buildInputs = with pkgs; [
                stdenv.cc.cc.lib
                zlib
                zstd
                gmp
                mpfr
                libmpc
                xz
                expat
                ncurses
                readline
                libusb1
              ];
              dontConfigure = true;
              dontBuild = true;
              installPhase = ''
                # The image bundles pacman (+ its libgpgme dependency) for
                # installing psp-packages into the SDK at image build time;
                # nothing here consumes it, and nixpkgs' gpgme has a different
                # soname than Ubuntu's, so autoPatchelf can never satisfy it.
                # Drop the tree rather than pin a library nothing calls.
                rm -rf ./share/pacman
                cp -r . "$out"
              '';
              postFixup = ''
                # Compile the JAL-relocation-aware psp-fixup-imports from the
                # pinned pspsdk sources plus this repo's patch, exactly the two
                # steps scripts/build_psp_fixup_imports.bash performs on a
                # hand-installed SDK (its config.h note applies verbatim:
                # tools/types.h includes config.h unguarded).
                cp -r "${pspsdkFixupSrc}" ./fixup-src
                chmod -R u+w ./fixup-src
                patch -s -p1 -d ./fixup-src < ${./patches/psp-fixup-imports-jal-relocation-aware.patch}
                cp ${./patches/psp-fixup-imports-config.h} ./fixup-src/config.h
                cc -O2 -DHAVE_CONFIG_H \
                  -I./fixup-src -I./fixup-src/tools \
                  -o ./fixup-built \
                  ./fixup-src/tools/psp-fixup-imports.c \
                  ./fixup-src/tools/getopt_long.c \
                  ./fixup-src/tools/sha1.c
                install -m 755 ./fixup-built "$out/bin/psp-fixup-imports"
              '';
            };

          # The emulator the `psp-smoke` CI job boots the EBOOT under. Based on
          # nixpkgs' own package, but the local patch below changes its output
          # hash, so it no longer matches what cache.nixos.org has prebuilt for
          # the channel this flake pins -- every `nix build '.#ppsspp'` compiles
          # PPSSPP from source instead of substituting a closure. That is a
          # multi-minute C++ build, so the `psp-smoke` job caches the Nix store
          # across runs (the same `cache-nix-action` step every other job in
          # `.github/workflows/build.yml` already uses) to avoid paying it on
          # every push.
          #
          # The default (non-Qt) build is the one that carries what the smoke
          # test needs: it configures with -DHEADLESS=ON and installs the
          # headless binary as `$out/bin/ppsspp-headless`, next to the SDL
          # frontend. Its assets are found without a working directory dance --
          # the real binary sits in $out/share/ppsspp/bin, and PPSSPP's headless
          # entry point walks up from the executable looking for assets/flash0,
          # which lands on $out/share/ppsspp/assets one level up.
          #
          # Linux-only, matching the package's own meta.platforms: forcing this
          # attribute on darwin (e.g. `nix flake show`) would otherwise throw.
          #
          # Carries several local patches on top of nixpkgs' build, all found
          # and root-caused while trying to read the PSP EBOOT's own boot log
          # under PPSSPP-headless (see docs/adr/0047-psp-memory-budget.md and
          # app/psp/README.md); none are upstreamed to hrydgard/ppsspp yet,
          # so all of them are applied here so this flake's own `ppsspp`/
          # `ppsspp-headless` survive past them. nix/patches/ has the full
          # patches and each one's own note on when it is safe to drop.
          #
          #   - sceKernelCreateLwMutex (Core/HLE/sceKernelMutex.cpp)
          #     dereferences its caller-supplied workarea pointer without
          #     validating it first, unlike every sibling LwMutex function in
          #     the same file -- a guest passing workareaPtr=0 turns that
          #     into a null-pointer write that segfaults the *host* emulator
          #     process rather than raising a guest-catchable error.
          #   - The interpreter's mfic/mtic (Core/MIPS/MIPSInt.cpp) are
          #     no-ops instead of touching the interruptsEnabled flag PPSSPP
          #     already tracks for the equivalent syscalls, so pspsdk's own
          #     fast interrupt-disable/enable (built directly on those two
          #     instructions, used to guard its non-reentrant C-runtime
          #     state) provides no real protection under PPSSPP.
          #   - Common/x64Analyzer.cpp's crash-recovery disassembler (used by
          #     Core/MemFault.cpp when bIgnoreBadMemAccess lets a bad guest
          #     access be skipped instead of halting) has no case for the
          #     0x88/0x8A 8-bit-register MOV opcodes, only their 32/64-bit
          #     counterparts -- so a bad access from an ordinary byte
          #     store/load hard-stops emulation instead of being skipped like
          #     every other access width already is.
          #   - Four SysclibForKernel imports (strtoul/strncat/memchr/
          #     tolower) this EBOOT pulls in have no HLE handler at all,
          #     silently no-opping and leaving register garbage instead of
          #     doing the real operation.
          #   - sysclib_memset/sysclib_memmove (also SysclibForKernel) return
          #     0 instead of their destination pointer, unlike every sibling
          #     pointer-returning function in the same file (sysclib_memcpy,
          #     sysclib_strcat, ...) -- breaking any caller relying on real
          #     memset()/memmove()'s C-standard return value, including GCC's
          #     own "memset(p, ...); return p;" idiom optimization, which
          #     silently becomes "return memset(...)" and returns PPSSPP's
          #     wrong 0 instead of the real pointer.
          #   - sysclib_strchr/sysclib_strrchr (SysclibForKernel again) call
          #     std::string::find(str, c) -- "find this whole string inside
          #     itself starting at offset c" -- where they meant
          #     find((char)c). Every lookup therefore returns the string
          #     itself for c == 0 and NULL for everything else, whatever the
          #     string holds, and newlib's path splitting on '/' rides on
          #     exactly these two.
          #   - Core/HLE/sceIo.cpp's path-taking functions (sceIoDopen,
          #     sceIoChdir, sceIoRemove, sceIoRmdir) dereference the guest
          #     pointer WrapU_C hands them without checking it, so a bad
          #     path builds a std::string from nullptr and terminates the
          #     host process -- the same class as the LwMutex bug above.
          ppsspp = pkgs.ppsspp.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ./nix/patches/ppsspp-lwmutex-workarea-validate.patch
              ./nix/patches/ppsspp-mfic-mtic-interrupt-mask.patch
              ./nix/patches/ppsspp-x64analyzer-8bit-mov.patch
              ./nix/patches/ppsspp-sysclibforkernel-missing-functions.patch
              ./nix/patches/ppsspp-sysclib-memset-memmove-return-value.patch
              ./nix/patches/ppsspp-sysclib-strchr-strrchr.patch
              ./nix/patches/ppsspp-sceio-null-path-validate.patch
            ];
          });
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
            # load-bearing for the shell — `scripts/rtp_install.bash` /
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

          # PSP development: everything `psp-cmake`/`cmake --build` needs to
          # configure and build app/psp's EBOOT, plus this flake's patched
          # PPSSPP headless build for running it (the same binary CI's
          # psp-smoke job uses). The toolchain is the packaged upstream
          # release above -- no hand-installed ~/dev/pspdev required; the
          # patched psp-fixup-imports app/psp/CMakeLists.txt insists on ships
          # inside it.
          #
          # Host tools mirror what the psp CI job's container gets from apk
          # plus what mruby's host half needs on a nix machine (the gperf/
          # bison trap from PSP-HANDOFF.md's environment notes applies here
          # too: without them, a stale direnv shell fails in mruby's lexer
          # regeneration and leaves a zero-byte lex.def behind).
          #
          # Linux-only: packages.pspdev is an x86_64-linux tarball and
          # packages.ppsspp is Linux-only anyway. On darwin, use the default
          # devshell plus upstream's macOS release tarball by hand.
          psp = pkgs.mkShell {
            packages =
              with pkgs;
              [
                self.packages.${system}.pspdev
                cmake
                ninja
                ruby
                bison
                gperf
                git
                autoconf
                automake
                pkg-config
                pre-commit
              ]
              ++ nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                self.packages.${system}.ppsspp
              ];
            PSPDEV = "${self.packages.${system}.pspdev}";
            CMAKE_BUILD_TYPE = "MinSizeRel";
            shellHook = ''
              echo "psp shell: PSPDEV=$PSPDEV"
              "$PSPDEV/bin/psp-gcc" --version | head -1
              echo "build:  psp-cmake -S app/psp -B build-psp && cmake --build build-psp"
              echo "run:    ppsspp-headless --log --graphics=software build-psp/EBOOT.PBP"
            '';
          };
        }
      );
    };
}
