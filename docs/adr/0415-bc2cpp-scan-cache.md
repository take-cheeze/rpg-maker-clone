# 0415. bc2cpp: a disk memo of the native-source scans, off unless asked for

Date: 2026-10-12

## Status

Accepted

## Context

A closed-world bc2cpp run reads the outside-world sources (mruby's C, the gems' C and C++, about 82 files and
2.3 MB) and scans them before it compiles anything. The check scripts start one `bc2cpp.rb` process per
fixture, so a shard such as `numeric_slow` (79 calls) or `call-facts` repeats those scans hundreds of times
over files that do not change. Profiling with StackProf (docs/bc2cpp-ci-duration-profile.md) put `String#scan`
at 42% of a one-method call, and 61% after the exact fixes that removed a per-line regex build
(`CoreMixins.definers_in`), a double scan (`class_variable_map`) and mid-word regex starts.

What is left is the scanning itself. The in-process caches that exist (`NativeExpressionDevirt::SOURCE_CACHE`
and `REGISTRATION_CACHE`, and the later dataflow-query and decoded-tree caches of ADRs 0409 and 0411) cannot help the
repeated scans, because every fixture call is a new process. Measured on the same one-method
call, the scans that are pure functions of their input files are, by inclusive time:

| Scan | Share of a 3.6 s call |
| --- | ---: |
| `NativeExpressionDevirt.analyze_exact_class_expressions` | 20.6% |
| `outside_world_tokens` (called twice per run) | 9.1% |
| `NativeExpressionDevirt.analyze` | 5.7% |

`ClosedWorld#scan_native`, `CallFacts::Answers#native_scan` and `NativeDirect.*` are about 20% more, but they
fill instance state as they scan and are not pure functions.

Alternatives considered:

* **A warm generator process** (a server, or a fork per call) would remove every repeated cost, including
  the class-layout and emission phases. It needs the generator's global state (`CodeGen` class-level
  attributes, module constants filled per run) to be reset between calls; that is a larger and riskier change
  than a scan cache and is left open.
* **Batching several fixtures into one process** has the same global-state problem.
* **Caching whole generator outputs** does not apply: none of the 79 calls of `numeric_slow` repeats an earlier
  one (digest of argv, environment and fixture text).
* **Memoizing `SourceText.read`** was tried and changed nothing: the files are in the page cache and the cost is
  the scanning.
* **Caching the stateful scans** needs each of them rewritten to return a value first.

## Decision

Add `tools/bc2cpp/scan_cache.rb` (`ScanCache.fetch(name, inputs) { scan }`), a content-addressed disk memo,
and route the three pure scans above through it. The block runs only when no entry exists.

* **Off by default.** Nothing is read or written unless `BC2CPP_SCAN_CACHE_DIR` names a directory. The nightly
  workflow sets it per job to `$RUNNER_TEMP/bc2cpp-scan-cache`; a developer can set it to any directory they own.
* **The key** is the SHA-256 of the cache version, the scan's name, a digest of every `tools/bc2cpp/*.rb` source,
  and for each input file its path and the digest of its bytes. A change to any scanner source, to a native
  source, or to the list or order of files is a different key. The tool digest is also what keeps the mutation
  checks sound: a mutant is a copy of `tools/bc2cpp`, so it never reads an entry written by the original.
* **Inputs are explicit.** `analyze` and `outside_world_tokens` read only the paths they are given;
  `analyze_exact_class_expressions` also reads the public API headers under `3rd/mruby/include`, so its inputs
  are the paths plus `public_api_header_paths`. A header that does not exist is part of the key as absent. A scan
  that reports a missing file (`outside_world_tokens`, through `SourceText`) passes `cache_absent: false` and is
  computed rather than stored, so its warning is never lost. An input that is a directory is not keyed.
* **Entries** are Marshal dumps written to a private name and renamed, so a concurrent reader (a `ci:parallel`
  group) sees a whole entry or none. A hit returns a freshly loaded object; a miss returns the scan's own.
* **Failures are reported.** An entry that cannot be loaded, a value that cannot be dumped and a directory that
  cannot be written each print a `[bc2cpp]` line to stderr and the scan result is returned as if the cache
  were off.
* **Exactness is checked, not assumed.** `scripts/bc2cpp/scan_cache_check.rb` (in `ruby-checks`) covers off by
  default, hit and miss, the order and content of the inputs, a changed scanner source, absent and directory
  inputs, the three failure reports, four concurrent writers, and the three real scans over mruby's C sources
  returning the same with the cache off, cold and warm. Three hand mutants of the key (no tool digest, no
  file content, absent inputs always stored) each fail it.

A scan may be routed through the cache only if (1) it reads nothing but the files in its input list, (2) it reads
no environment variable, (3) it has no side effect, including a warning on success, and (4) its result is plain
data that Marshal can dump. The three scans were read for these four points: none uses `ENV`, none reads a file
outside its list, and each returns plain data (Hashes, Arrays, Sets, Strings, Symbols, Integers).

The stateful scans follow the same rule by splitting each into two parts. The scan itself is a function of its
inputs and returns plain facts; the caller replays them into its own state, in the same order. The three routed
this way:

* `ClosedWorld#scan_native` is now `ClosedWorld.native_facts(paths)` (one Hash per native source: its tokens,
  name and literal sets, constant writes, refusal reasons in order, touch facts) plus `apply_native_file`, which
  writes the closed world's ivars. The touch classification (`TouchScan.native_classify`) depends on the declared
  class names, which are not files, so it runs at replay and is not in the key; the text-reading part of
  `TouchScan.native` (the events and the local `mrb_sym` values they name) is the part in the key.
* `NativeExpressionDevirt.class_registrations` (what `CallFacts::Answers#native_scan` reads) stores the plain form
  of `scan_class_registrations`' two maps. Its callers get them back with the access-creates-empty defaults the
  scan always had, so `scan_class_registrations` itself is unchanged.
* `NativeDirect.file_registrations` is keyed by its file and every `*.cxx` beside it, since the parameter owners
  it resolves come from those siblings. Its per-process memo stays in `NativeDirect`.

Checked against the four points, for each of the three: (1) holds, the scan reads its listed files and nothing
else; the `ClosedWorld` replay is the only part that writes state and it is not cached. (2) holds, none reads
`ENV`. (3) holds for the scan: no ivar writes, no warnings. The `ClosedWorld` replay and the `NativeDirect` memo
write state by design, outside the cached part. (4) holds for the stored value: no default procs, no objects of
our own classes. Not satisfied: nothing. `scan_class_registrations` still returns hashes with default procs, so
`class_registrations` converts them for storage; that conversion is the only thing between the scan and the cache.

## Consequences

* A warm one-method call takes 2.7 s against 3.55 s with the cache off (-25%), with identical C++; cold costs
  about the same as off (3.45 s). `numeric_slow` in its `int32-a` configuration takes 316 s against 398 s (-21%, the same 329 checks passing).
  The first call of each job pays for the scans, the rest of the job's calls (all of its parallel group) load them.
* The first generator pass over the whole engine (21,620,134 bytes of C++) is byte-identical to the committed
  tool's with the cache cold and with it warm. That pass is not faster (486 s cold, 500 s warm): its time is in
  compiling methods, so the cache helps the fixture-based checks, not the engine build.
* The generated code is unchanged, which is why the cache needs no new proof about the compiler's output: it can
  only return what the scan would have returned for the same bytes.
* Marshal is only safe to load from a directory an attacker cannot write. The variable is therefore not set by
  default and the module says so; the CI directory is job-local under `$RUNNER_TEMP`.
* A cache directory grows by about 200 KB per distinct (tool sources, native sources) pair. A mutation check
  writes one set per mutant. Nothing prunes it; it lives and dies with the runner's temp directory.
* The key hashes `tools/bc2cpp/*.rb` once per process (about 30 ms) and the input files once per process (about
  20 ms); both are inside the 25% above.
* The cache is not saved between jobs (`actions/cache`): every job starts cold, which keeps a stale entry from
  surviving anything that the key does not cover. The key would allow it, since it holds the checkout's absolute
  paths and content digests only; it is a possible follow-up if the first call of each job is worth saving.
* The stateful scans now return values and use the cache (the section above). One-method call, medians of five
  interleaved runs (committed tool, then this change, per mode) on a 4-core box shared with other jobs (load 19 to
  22, so well above the quiet-box numbers above): warm 4.00 s to 2.88 s (-28%); cache off 5.64 s to 5.86 s (+4%);
  cold 5.21 s to 5.69 s (+9%). The warm gain is the scans now loaded; the off and cold cost is the facts being
  built and replayed in order, which the cache-off path now also does. Reducing that replay is a possible follow-up.
  The generated C++ is identical in all three modes (see the pull request).
* Follow-ups, in order of expected value: the warm-process alternative above, and saving the cache between jobs
  (see the bullet above it).
