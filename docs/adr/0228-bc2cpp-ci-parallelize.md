# 0228. Parallelize the bc2cpp CI job

Date: 2026-09-24

## Status

Accepted

## Context

The `bc2cpp` job in `.github/workflows/build.yml` ran everything on one
runner, one step after another. On a typical run (PR #1922, run 35963564494,
job 107517109277) it took 34.4 min:

| Step | Time |
|---|---|
| checkout, submodules, nix, sccache, configure | 1.6 min |
| Build host mruby with bc2cpp (`mruby_build`) | 12.2 min |
| `bc2cpp_coverage_check.bash` | 2.3 min |
| Optcarrot coverage + 180-frame benchmark | 4.7 min |
| 38 `scripts/bc2cpp_*_check.rb` runs | 13.5 min |

The check step's cost is uneven. In that run's log, the time between one
check's `PASS` line and the next was: `wired_embedding` 195 s,
`static_dispatch` 195 s, `nomethod_reviewed` + `hot_only` 164 s,
`never_called_registrations` 126 s, `embedded_ivar_access` 95 s, and about
40 s for the other 32 checks together.

Nothing after the build uses what the build makes. Every check, both coverage
reports and the Optcarrot benchmark read only three things:

- the bootstrap host `mrbc`;
- `host/mrbc/lib/libmruby_core.a` and `host/mrbc/include`, as
  `BC2CPP_MRUBY_CORE`;
- the patched source tree.

The full build's `libmruby.a` exists only to prove that the generated C++
compiles. mruby builds the bootstrap `host/mrbc` as its own gem-free build,
cloned from the host config (`MRuby::Build#create_mrbc_build`), and it does
not depend on any gem.

The build is a single `rake` run inside one CMake custom command, so
`cmake --build --parallel` could not reach it. It ran fully serially.

## Decision

Split the job into a graph of jobs that run at the same time:

- **`bc2cpp-build`** builds the full `RPGMAKER_BC2CPP=1` libmruby, as before.
  This is still the gate that proves the generated C++ compiles. rake now
  runs with `RAKEOPT: -m -j4`, which treats every task as a multitask, so the
  three compiled gems' codegen and all C/C++ compiles share the runner's four
  cores. `sccache --show-stats` now runs right after the build.
- **`bc2cpp-checks`**, a 7-shard matrix, starts at once, without waiting for
  the build. Each shard configures the project and builds only the bootstrap
  `mrbc`: the new `mruby_host_mrbc` CMake target, which runs the new
  `host_mrbc` rake task in `build_config.rb`. That takes a few seconds. The
  shard then runs its part of the old command list. The shards are balanced by
  the costs measured above:
  - `static-dispatch`
  - `wired-embedding`
  - `hot-only` (with `nomethod_reviewed`)
  - `registrations` (`embedded_ivar_access` + `never_called`)
  - `optcarrot-coverage`
  - `optcarrot-benchmark`
  - `fast` (the coverage report plus the 32 quick checks)
- **`bc2cpp`** is an aggregator job. It `needs:` both jobs and succeeds only
  if both succeeded, so the status-check name that branch protection may
  require is unchanged, and it still covers everything.

### Why it is as strict as before

- **Same command list.** The matrix holds exactly the 44 script invocations
  of the old job, each with the same environment. This was checked by
  comparing the parsed old and new workflows. The checks run from the same
  `build-bc2cpp/` path, so `BC2CPP_MRUBY_CORE` is the same directory.
- **Same bootstrap outputs.** `mruby_host_mrbc` applies the same patch list
  as `mruby_build` (one shared CMake list) and runs the same rake file rule.
  Built at the same path, its `bin/mrbc`, `lib/libmruby_core.a` and
  `include/` were byte-identical to a full build's. The only file missing
  was `mrbgems/active_gems.txt`, which no bc2cpp check reads.
- **No silent SKIP.** Several checks quietly `SKIP` their compiled comparison
  when `libmruby_core.a`/`include` is missing. Each shard now checks both
  first and fails if either is absent. This was confirmed by hiding the
  library.
- **Real failures still fail.** A deliberate violation (a `:avg_agi` symbol
  literal naming a `STATIC_DISPATCH_UNREGISTERED` method) failed
  `bc2cpp_static_dispatch_check.rb` through the shard's step, exactly as on
  master. It passed again once reverted.
- **Shards run to the end.** `fail-fast: false` lets every shard finish, so
  one failing check no longer hides the result of the checks after it.

### Making `rake -m` safe

Running rake with `-m` exposed three things that only worked because the
build ran in order:

1. **Missing `mrbc` dependency.** The three compiled gems' codegen `file`
   tasks and `wio_strip_bc2cpp_stubs`'s probe run `mrbc` but did not list
   `spec.build.mrbcfile` as a prerequisite. The serial build only ran them
   after `mrbc` because of the order tasks happened to be declared in. They
   now declare it.
2. **`Dir.chdir` blocks.** `mruby-lcf` and `mruby-rgss` ran their table
   generators inside `Dir.chdir` blocks. `Dir.chdir` changes the working
   directory of the whole process, so every rake thread is affected. Under
   `-m`, rake stopped with "conflicting chdir during another chdir block".
   Worse, a thread that does not call `chdir` itself could run a relative
   path in the wrong directory without any error. They now use
   `ruby ..., chdir:`, which changes only the child process's directory.
3. **Vendored onig-regexp.** `3rd/mruby-onig-regexp` builds its bundled
   onigmo the same way. `patches/mruby-onig-regexp-no-chdir.patch` gives each
   command its own working directory. It is applied like the other vendored
   patches.

A clean serial build and a clean `-m -j4` build, both at the same path,
produced byte-identical results:

- `libmruby.a` (99 MB) and all 273 object files;
- the three `*_gen.cpp` and `*_decls.h` files;
- presym;
- the bootstrap `mrbc` and `libmruby_core.a`.

`-m` is set only for this job (`RAKEOPT`), so the other builds keep running
rake serially. They could switch to it later.

### Rejected: hand the build over as an artifact

The first plan was for the build job to upload `build-bc2cpp/mruby` and for
the check shards to download it. That still makes every shard wait for the
full build (about 14 min), and it adds upload and download time. Building
the bootstrap `mrbc` in each shard takes seconds and needs no artifact at all.

### sccache

The old comment said the build ran uncached and set `CC: sccache gcc` on
the build step. That setting never took effect. `CMakeLists.txt` passes
`CC=${CMAKE_C_COMPILER_LAUNCHER} ${CMAKE_C_COMPILER}` to rake as a
command-line argument, and rake writes that value into `ENV`, overriding the
step's variable. So compiles already went through the dev shell's sccache
launcher. The step variable was dropped.

The old job's `sccache --show-stats` reported all zeros. That is because it
ran about 20 minutes after the last compile, and the sccache server shuts
down after 10 idle minutes. The stats step now runs right after the build.

## Measurements

Local, 4 cores, clean build of the same tree with CI's empty
`CFLAGS`/`CXXFLAGS`:

| Build | Time |
|---|---|
| `rake` (serial, as before) | 580 s |
| `rake -m -j4` | 343 s |
| `rake host_mrbc` (what each shard builds) | 7–9 s |

CI results: see "Results" below.

## Results

(Filled in from this PR's CI run.)

## Consequences

- The bc2cpp work in CI takes about as long as the full libmruby build plus
  setup, instead of the sum of every step.
- It uses more runner time: nine jobs, each paying about 1.5–2 min of
  checkout and nix setup, instead of one job.
- New bc2cpp checks go into one shard's `checks:` list. Put a fast check in
  `fast` and give a slow one its own shard. The matrix comment says so.
- The status check named `bc2cpp` still exists and still covers everything,
  so required status checks need no change. A repo admin may additionally
  require the new job names (`bc2cpp-build`, `bc2cpp-checks (...)`), but
  that is not needed for gating.
- A rake task that uses `Dir.chdir`, or runs a tool without declaring it as
  a prerequisite, now fails the `bc2cpp-build` job. It fails loudly, because
  a clean CI tree has no stale file to fall back on.
