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
        }
      );
    };
}
