# 0228. Parallelize the bc2cpp CI job

Date: 2026-09-24

## Status

Accepted

## Context

The `bc2cpp` job in `.github/workflows/build.yml` ran everything on one
runner, one step after another. On PR #1922 (run 35963564494, job
107517109277) it took 34.4 min:

| Step | Time |
|---|---|
| checkout, submodules, nix, sccache, configure | 1.6 min |
| Build host mruby with bc2cpp (`mruby_build`) | 12.2 min |
| `bc2cpp_coverage_check.bash` | 2.3 min |
| Optcarrot coverage + 180-frame benchmark | 4.7 min |
| 38 `scripts/bc2cpp_*_check.rb` runs | 13.5 min |

Across the last 38 successful runs, the whole job took between 19.0 and
37.4 min (median 28.4 min). The build step alone took 316–979 s (median
522 s); how long depended on how much sccache already had cached.

The checks do not all cost the same. In that run's log, the time between one
check's `PASS` line and the next was:

| Check | Time |
|---|---|
| `wired_embedding` | 195 s |
| `static_dispatch` | 195 s |
| `nomethod_reviewed` + `hot_only` | 164 s |
| `never_called_registrations` | 126 s |
| `embedded_ivar_access` | 95 s |
| the other 32 checks together | about 40 s |

Nothing after the build uses what the build makes. Every check, both coverage
reports and the Optcarrot benchmark read only three things:

- the bootstrap host `mrbc`;
- `host/mrbc/lib/libmruby_core.a` and `host/mrbc/include`, as
  `BC2CPP_MRUBY_CORE`;
- the patched source tree.

The full `libmruby.a` exists only to prove that the generated C++ compiles.
mruby builds the bootstrap `host/mrbc` as its own gem-free build, cloned from
the host config (`MRuby::Build#create_mrbc_build`), so it does not depend on
any gem.

The build is a single `rake` run inside one CMake custom command, so
`cmake --build --parallel` could not reach it, and rake ran serially.

## Decision

Split the job into a graph of jobs that run at the same time:

- **`bc2cpp-build`** builds the full `RPGMAKER_BC2CPP=1` libmruby, as before.
  It is still the gate that proves the generated C++ compiles. rake now runs
  with `RAKEOPT: -m -j4`, which treats every task as a multitask, so the
  three compiled gems' codegen and all C/C++ compiles share the runner's four
  cores. `sccache --show-stats` now runs right after the build.
- **`bc2cpp-checks`** is a 6-shard matrix that starts at once and does not
  wait for the build. Each shard configures the project and builds only the
  bootstrap `mrbc`, with the new `mruby_host_mrbc` CMake target (which runs
  the new `host_mrbc` rake task in `build_config.rb`). That takes 11–20 s.
  The shard then runs its part of the old command list. The shards are
  balanced by the costs measured above:

  | Shard | Checks |
  |---|---|
  | `static-dispatch` | `static_dispatch` |
  | `wired-embedding` | `wired_embedding` |
  | `hot-only` | `nomethod_reviewed`, `hot_only` |
  | `registrations` | `embedded_ivar_access`, `never_called_registrations` |
  | `optcarrot-benchmark` | the Optcarrot benchmark |
  | `fast` | both coverage reports and the 32 quick checks |

- **`bc2cpp`** is an aggregator. It `needs:` both jobs and succeeds only when
  both succeeded. The status-check name that branch protection may require is
  unchanged, and it still covers everything. In this PR's first run, one
  failing shard turned `bc2cpp` red, as intended.

### Why it is as strict as before

- **Same commands.** The matrix holds exactly the 44 script invocations of
  the old job, each with the same environment. This was checked by comparing
  the parsed old and new workflow YAML.
- **Same paths.** The checks run from the same `build-bc2cpp/` path, so
  `BC2CPP_MRUBY_CORE` is the same directory.
- **Same bootstrap files.** `mruby_host_mrbc` applies the same patch chain as
  `mruby_build` and runs the same rake file rule. Built at the same path, its
  `bin/mrbc`, `lib/libmruby_core.a` and `include/` were byte-identical to a
  full build's. The only file missing was `mrbgems/active_gems.txt`, which no
  bc2cpp check reads.
- **No silent SKIP.** Several checks quietly `SKIP` their compiled comparison
  when `libmruby_core.a` or `include` is missing. Each shard now checks both
  first and fails if either is missing; this was tested by hiding the library.
- **Real failures still fail.** A deliberate violation made the shard fail
  `bc2cpp_static_dispatch_check.rb` exactly as on master: a `:avg_agi` symbol
  literal, which names a `STATIC_DISPATCH_UNREGISTERED` method. With the
  violation reverted, the check passed again.
- **Every check runs.** `fail-fast: false` lets every shard finish, so one
  failing check no longer hides the result of the checks after it.

### Making `rake -m` safe

`-m` showed three places where the serial build had only worked because rake
happened to run tasks in the order they were declared:

1. **Missing prerequisite.** The three compiled gems' codegen `file` tasks,
   and `wio_strip_bc2cpp_stubs`'s probe, run `mrbc` but did not list
   `spec.build.mrbcfile` as a prerequisite. Now they do.
   - Two existing checks match these prerequisite lists as literal text.
     `bc2cpp_hot_only_check.rb` needs the list to end with
     `BC2CPP_HOT_METHODS_PATH]`, and `bc2cpp_mrbgem_deps_check.rb` needs it
     to start with `*bc2cpp_tool_srcs`.
   - So `mrbcfile` sits in the middle, after `compiled_gems_rb`, and neither
     check changed. Both checks caught earlier placements in this PR's CI.
2. **`Dir.chdir` blocks.** `mruby-lcf` and `mruby-rgss` ran their table
   generators inside `Dir.chdir` blocks. `Dir.chdir` changes the working
   directory of every rake thread at once.
   - Under `-m`, rake stopped with "conflicting chdir during another chdir
     block".
   - Worse, a thread that does not call `chdir` itself would silently run
     its relative paths in the wrong directory.
   - The generators now use `ruby ..., chdir:`, which changes the directory
     only for that child process.
3. **Vendored onig-regexp.** `3rd/mruby-onig-regexp` builds its bundled
   onigmo the same way. `patches/mruby-onig-regexp-no-chdir.patch` gives
   each command its own working directory. It is applied like the other
   vendored patches.

A clean serial build and a clean `-m -j4` build, both at the same path,
produced byte-identical output: `libmruby.a` (99 MB), all 273 object files,
the three `*_gen.cpp`/`*_decls.h` files, presym, and the bootstrap
`mrbc`/`libmruby_core.a`. `-m` is set only for this job, through `RAKEOPT`,
so the other builds keep running rake serially.

A new rake task that uses `Dir.chdir`, or runs a tool without declaring it as
a prerequisite, now breaks `bc2cpp-build` loudly. A clean CI tree has no
stale file to fall back on.

### The patch list

`cmake/build-mruby.cmake` now builds one `apply_mruby_patch.bash ... &&` chain
with a `rpg2k_mruby_patch(dir patch)` macro, which also collects the patch
files for DEPENDS. Both `mruby_build` and `mruby_host_mrbc` use this chain.
The generated ninja command for `libmruby.a` is byte-identical to master's,
apart from the new onig patch step.

### Rejected: pass the build to the checks as an artifact

The first plan was for `bc2cpp-build` to upload `build-bc2cpp/mruby` for the
shards to download. Every shard would then still wait for the full build
(about 14 min) plus the upload and download. Building the bootstrap `mrbc`
in each shard takes seconds and needs no artifact at all.

### sccache

The build step used to set `CC: sccache gcc`, next to a comment saying the
mruby build ran uncached. Neither was accurate:

- `CMakeLists.txt` passes `CC=${CMAKE_C_COMPILER_LAUNCHER} ${CMAKE_C_COMPILER}`
  to rake on its command line, and rake writes that into `ENV`. The step's
  variable was always overridden, and compiles already went through the dev
  shell's sccache. The step variable is removed.
- The old job's `sccache --show-stats` printed all zeros only because it ran
  about 20 min after the last compile. By then the sccache server had
  stopped, after 10 idle minutes, and a fresh one answered.

## Results

These are real GitHub Actions timings, from the first job start to the
`bc2cpp` aggregator finishing:

| Run | bc2cpp-area wall-clock | Build step |
|---|---|---|
| Old job, PR #1922 (35963564494) | 34.4 min | 732 s |
| Old job, median of 38 runs | 28.4 min (19.0–37.4) | 522 s (316–979) |
| New graph, all green, sccache warm: 35974219974 (7 shards) | **6.4 min** | 250 s (313/313 hits) |
| New graph, forced uncached with `SCCACHE_RECACHE=1`: 35975110440 (6 shards, temporary commit) | **13.1 min** | 628 s (313 misses) |

- **Critical path.** Once the build is uncached, it is the critical path.
  Every shard finished within 6.4 min in both runs; the longest shard, the
  Optcarrot benchmark, took 6.3–6.4 min including setup.
- **Where the uncached build time goes.** The uncached build spent only
  about 451 CPU-seconds in the compiler (313 × 1.44 s). The rest of its
  628 s is serial work that `-m` cannot split: the single 17 MB
  `rpg2k_compiled_gen.cpp` translation unit, and the `bc2cpp.rb`
  codegen/probe runs for each gem.
- **Controlled local measurement.** On 4 cores, uncached, with CI's empty
  `CFLAGS`: serial `rake` took 580 s and `rake -m -j4` took 343 s (-41%).
  `rake host_mrbc` alone took 7–9 s.

## Consequences

- **Wall-clock.** The bc2cpp work now takes about as long as the full
  libmruby build plus setup: 6.4 min warm and 13.1 min cold, instead of
  19–37 min.
- **Runner time.** It uses more runner time: eight jobs, not one. Each shard
  pays about 1.5–2 min of checkout, nix and configure. The shards finish
  before a cold build does, so this adds no wall-clock.
- **Adding a check.** A new bc2cpp check goes into one shard's `checks:`
  list. A fast one goes in `fast`; a slow one (over about 2 min) gets its
  own shard. The matrix comment says this.
- **Required checks.** `bc2cpp` still exists and still covers everything, so
  required status checks need no change. A repo admin may additionally
  require `bc2cpp-build` and `bc2cpp-checks (...)`, but gating does not need
  them.
- **Next speed-up.** The next lever is the cold build's serial tail: the one
  huge generated translation unit, and codegen for each gem.
