- `scripts/native-build-without-nix.bash`'s system-package step gated only on
  `sdl2`/`SDL2_mixer` being present, so a container that already had those dev
  headers (as this project's own agent sandbox does) but not `gperf`/`bison`
  skipped the whole install branch and failed ~700 ninja steps later with a bare
  `sh: 1: gperf: not found` deep inside mruby's own rake build — this project's
  `mruby-defined-keyword.patch` touches `mrbgems/mruby-compiler/core/keywords`,
  which forces `lex.def`/`y.tab.c` to regenerate on every build (see
  `flake.nix`'s own comment on this pair), not just the first time the patch
  lands. The gate now checks every tool this step is responsible for
  (`cmake`/`ninja`/`g++`/`xvfb-run`/`gperf`/`bison`, not only the two SDL2
  `pkg-config` entries) before deciding the system is already provisioned.
