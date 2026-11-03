# Prism readers in the bc2cpp scan cache

[Source-parse allocations](bc2cpp-parse-cache-allocations.md) found that most
of the Prism parses left in a warm compile are the `mruby-rpg2k` sources, and
that a file's parse can be skipped only when **every** reader of that file
gets its facts from a cache. This page covers the three readers that now do,
and why their cache keys are sound.

## Who reads which file

Logging every `RubyParseCache` lookup in a warm, fixed-path compile of the
sealed Optcarrot world (master `b06ca7f7a`) groups the files by the set of
readers that ask for them:

| Files | Bytes | Readers |
| ---: | ---: | --- |
| 24 | 2,604,554 | `DispatchTargetSources.class_initializers`, `ClassBodyScan.scan`, `ClassWorld.dynamic_sites` |
| 8 | 257,313 | `ClassBodyScan.scan`, `ClassWorld.dynamic_sites` |
| 5 | 94,276 | `NativeConstructorSigs.ruby_initialize`, `ClassBodyScan.scan`, `ClassWorld.dynamic_sites` |
| 1 | 1,458 | `DispatchTargetSources.class_initializers` |
| 1 | 128,166 | `PredicateReturns.violations_in`, `ConversionReturns.found_in` |
| 41 | 217,655 | the foreign-Ruby scans and the compiled-gems owner walk (up to six readers per file); 22 of these files are also read by `ClassBodyScan.scan` and `ClassWorld.dynamic_sites` |

`ClassBodyScan.scan` and `ClassWorld.dynamic_sites` run only inside a
`ClassWorld` build (`ClassWorldGate.world`, `ClassWorld.from_load_world`).
So the first four rows, 2,957,601 bytes, need just three cached readers. The
last two rows are still parsed: `ConversionReturns` keeps Prism nodes in its
results, and the foreign files have up to six readers each for 7% of the
bytes.

## The cached readers

All three use `ScanCache.fetch`, whose key already holds the digest of every
`tools/bc2cpp` source, the Ruby version and platform, the Marshal format, and
the SHA-256 of each input file. Each entry name adds `Prism::VERSION`. Every
entry passes `cache_absent: false`, so a missing file is never cached and
fails as before. An exception inside the block (a syntax error, a missing
file) is raised before anything is stored.

| Entry | Inputs | Value |
| --- | --- | --- |
| `dispatch_targets.class_initializers.prism<V>` | one `mrblib` file | the class names whose body defines `initialize`, in first-seen order |
| `native_constructor_sigs.ruby_initialize.<Class>.prism<V>` | one `mruby-rgss/mrblib` file | `[String helper, else helper]`, `:refused`, or `nil` |
| `class_world.build.prism<V>.<shape>` | every file of every root, in load order | the whole `ClassWorld::World` |

**`DispatchTargetSources.file_initializers`.** `collect_initializers` walks
one tree and reads nothing else. `class_initializers` merges the per-file
lists into one Hash in file order. A key already present keeps its place, so
the merged Hash has the same keys in the same order as the single shared
Hash it replaces.

**`NativeConstructorSigs.ruby_initialize_helpers`.** This is the Ruby half
of `ruby_initialize`: find the `def initialize` of the class with that last
name segment, check that it has the `kind_of? String` form, and return the
two `self.` helper names. The class name is part of the entry name because the
result depends on it. The C half (`registered_body`, `c_overloads`) still
runs on every compile, against the C sources, as before.

**`ClassWorld.build_files`.** A World depends on more than one file: the
`defined` set and the superclass and mixin resolution read every root. So the
cache stores the whole World, keyed by every file it reads. Its other inputs:

- How the files are grouped into roots. The entry name ends with a digest of
  the group sizes, so the same files grouped differently are a separate
  entry.
- `PureEval.fold`, which runs constant expressions under CRuby. It reads only
  the statement and earlier constants of the same body (in the key), calls
  only the methods in `PureEval::METHODS`, and names only `CORE_CONSTS`. Its
  answer can depend on the Ruby that runs it, which is in the key.
- `frozen_magic?`, which reads the first lines of a file that is in the key.
- `ClassWorld::NATIVE` and the scanners, which are `tools/bc2cpp` sources.

A cached scan may not read `ENV` (`ScanCache::EnvGuard`), and none of these
do. The World holds Structs, Hashes, Arrays, Strings, Symbols and Integers.
Marshal keeps shared references inside one dump, so a fact's `includes` Array
is still the same object as the World's `facts[...]['includes']`. Every reader
only reads the World. `ClassWorldGate.world` still answers nil when the graph
cannot be derived, but a `ScanCache::Error` is raised, not turned into nil.

`RubyParseCache` already parses only when a reader asks. When all three
caches hit, nothing asks for these files, so they are never read or parsed.

## Evidence

`scripts/bc2cpp/ruby_parse_cache_check.rb` (section "Prism readers kept in the
scan cache") uses a private cache directory. It checks these things:

- The three readers give the same answers from a cold cache, from a warm
  cache, and under `ScanCache.bypass`. This is checked for the 59 closed-build
  files, for every rgss file and class name pair, and for fixtures.
- A warm read of all three calls `Prism.parse` zero times.
- A rewritten file is scanned again.
- Two groupings of the same fixture files each match their own fresh build.

Measurements used Ruby 4.0.5, Prism 1.8.1, the profiling `mrbc`, and the
sealed Optcarrot world. Before and after runs alternated in `--mode none`.
Only the four compiler files differed. Each version got one warm-up run
before the warm and `--optcarrot` sets. Cold runs deleted
`build/bc2cpp-cache` before every run.

| Cache | Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | --- | ---: | ---: | ---: | ---: |
| warm, fixed world | 1 | 6,378,044 | 5,836,884 | 8.544 | 8.602 |
| warm, fixed world | 2 | 6,378,044 | 5,836,883 | 9.307 | 8.273 |
| warm, fixed world | 3 | 6,378,004 | 5,836,887 | 8.280 | 8.511 |
| cold, fixed world | 1 | 7,752,030 | 7,753,932 | 10.650 | 10.618 |
| cold, fixed world | 2 | 7,751,794 | 7,753,911 | 10.769 | 11.424 |
| cold, fixed world | 3 | 7,751,773 | 7,754,024 | 10.667 | 10.552 |
| `--optcarrot` temp world | 1 | 6,755,237 | 6,214,367 | 10.338 | 8.984 |
| `--optcarrot` temp world | 2 | 6,755,185 | 6,214,383 | 9.261 | 8.919 |
| `--optcarrot` temp world | 3 | 6,755,699 | 6,214,269 | 9.293 | 9.041 |

- **Warm:** 541,146 fewer allocations per compile (8.48%).
- **Cold:** 2,090 more (0.03%). This is the cost of dumping the new entries.
- **`--optcarrot`:** 541,034 fewer (8.01%). All the inputs are repository
  files, so these entries hit even when the world path changes.

In warm object profiles, `Prism.parse` drops from 3,454 of 63,752 samples
(5.42%) to 583 of 58,344 (1.00%). The new entries take 82,633 bytes on disk,
77,750 of them for the World. Generated C++ was byte-for-byte identical across
all 14 fixed-path runs. The `--optcarrot` outputs differed only in the
temporary world path, plain and hex-escaped. Timing varied by more than the
differences between versions in the warm and cold sets, so these runs do
**not** show a speedup. The demonstrated result is the reduction in
allocations.
