# bc2cpp trace host: running the closed libmruby.a headlessly

`scripts/bc2cpp/trace_host.bash` links the closed bc2cpp library
(`scripts/bc2cpp/closed_build.bash`, `closed/lib/libmruby.a`) into a small
host executable, `trace_host.cxx`, that boots the RPG2000 sample game
Nepheshel with no window and no SDL. It starts New Game, runs a bounded
number of `RPG2k#main_loop` frames and exits normally, so the
`BC2CPP_TRACE_TYPES` atexit dump is written.

## Verdict

Feasible on a Linux host, with no SDL, PSP or Wio code. The closed library's
undefined symbols (computed with `nm -u` against `nm --defined-only` over
the archive) fall into three groups:

- libc, libm, libstdc++ and pthread (`fopen`, `clock_gettime`, `std::thread`, ...).
- LVGL 9 (`lv_display_create`, `lv_timer_handler`, `lv_snapshot_take`, ...,
  about 60 symbols). Built from `3rd/lvgl/src` against `include/lv_conf.h`,
  the config the device builds use.
- uni-algo's data unit (`una::detail::stage*_decomp_nfd`, `stage*_ccc_qc`).
  Built from `3rd/uni-algo/src/data.cpp` with the five `UNI_ALGO_DISABLE_*`
  trims `build_config.rb` applies.

The platform hooks the RGSS natives call (`rgss_sdl_poll`, `rgss_terminal_poll`,
`rgss_audio_frame`, `log_bridge_write`, `window_title_set`) are defined inside
the closed library itself, as no-op backends. `rgss_set_display` is also
defined there. So a host needs no stubs for Graphics, Audio or Input: it
supplies `main()`, the LVGL display and tick callbacks, and the game
constants. File IO goes through the closed build's own `hal-wio-io`, which
calls plain POSIX `open`/`read`/`fstat`, so it works on Linux unchanged.

## Running it

```bash
# 1. Closed build (plain, for compile checking; traced, for trace rows).
scripts/bc2cpp/closed_build.bash /tmp/closed-build
BC2CPP_TRACE_TYPES=1 scripts/bc2cpp/closed_build.bash /tmp/closed-trace-build

# 2. Game data (scripts/download/nepheshel.bash uses unar; unzip works too).
#    The RPG2000 New Game variant is Nepheshel206beta/Nepheshel206Rbeta.

# 3. Host: builds LVGL and uni-algo, the driver, runs it, checks the dump.
scripts/bc2cpp/trace_host.bash /tmp/closed-trace-build data/Nepheshel206beta/Nepheshel206Rbeta
```

`trace_host.bash` reads `BC2CPP_HOST_FRAMES` (default 600) and
`BC2CPP_TRACE_TYPES_OUT` (default `BUILD_DIR/trace-host/param_trace.tsv`).
It writes `run.log` beside the dump. It fails if the library is a traced
build and the dump has no `PARAM_`/`RETURN_` rows. For a plain build it
prints a note instead, since there is no dump to check.

Inspect the dump with the existing tool:

```bash
ruby scripts/bc2cpp/trace_types.rb report BUILD_DIR/trace-host/param_trace.tsv
```

## Results (this host, 4 cores)

- Plain closed build: `built .../closed/lib/libmruby.a`; the traced build
  (`BC2CPP_TRACE_TYPES=1`) completed in about 4 minutes after the plain build.
- Host, plain library: New Game reached `RPG2k::Scene::Map` by frame 50 and
  stayed there through frame 600 with no Ruby exception.
- Host, traced library: the same run, plus a dump of 15,631 rows
  (`PARAM_*` and `RETURN_*`, across `rpg2k_compiled` and `core_compiled`).
  `trace_types.rb report` reads it and reports 147 parameters reached at run
  time, plus one static-fact contradiction, which the tool prints as
  `Game::Interpreter#skip_to req1`. That is a finding for the report to
  examine, not a verified bug.

Caveats: no keys are pressed, so the run covers only the title-to-map path
(New Game is selected by `RPG2K_NEW_GAME`). The sample size is one game and
one 600-frame run. Scene::Map is sampled every 50 frames, so the exact
transition frame is not recorded.

## Build prerequisites found on the way

`closed_build.bash` needs more submodules than its header lists. Each one
was discovered by a failing build step, in this order: `3rd/mruby-onig-regexp`
(the bootstrap host half of `build_config.rb` loads it even for `closed`),
`3rd/uni-algo`, `3rd/stb` (`mruby-rgss/src/iterm.cxx`), `3rd/lvgl`
(`mruby-rgss` include path), and `3rd/quickjs` (`mruby-mvjs`'s host half),
along with `3rd/mgem-list`, `3rd/ng-log`, `3rd/inicpp` and `3rd/gflags`.
Initialise them with
`git submodule update --init --depth 1 3rd/mruby 3rd/mruby-stringio 3rd/mruby-marshal 3rd/mruby-onig-regexp 3rd/uni-algo 3rd/stb 3rd/lvgl 3rd/quickjs 3rd/mgem-list 3rd/ng-log 3rd/inicpp 3rd/gflags`.
`rake` must be on `PATH`. The bootstrap `mrbc` build needs `bison` and `gperf`.

The build also applies the patches in `scripts/mruby/standalone_prep.bash` to
the submodule working trees, so `git status` in `3rd/mruby`,
`3rd/mruby-stringio` and `3rd/mruby-marshal` shows modified files afterwards.
Those are build outputs, not commits. The superproject's recorded pointers
do not change.

## Not done

- No CI job runs `trace_host.bash`. Wiring it in needs a Nepheshel download
  step, the traced closed build, and an artifact upload for the dump.
- The trace host does not drive input, audio or battles, so the traced
  coverage is limited to what New Game and 600 idle frames execute.
