# Source-parse allocations in the bc2cpp compiler

Every generator run starts a new Ruby process, and some of its scans parse
the same unchanged sources again. On master, an object-mode profile of the
sealed Optcarrot compile with a warm scan cache attributed these shares of
83,979 allocation samples to parsing:

| Frame | Samples | Share | Called from |
| --- | ---: | ---: | --- |
| `Prism.parse` | 3,374 | 4.0% | `RubyParseCache.parse` (96%), `bc2cpp_rpg_maker_gem_lines` |
| `RBS::Parser._parse_signature` | 1,882 | 2.2% | `NativeSigs.parse`, which parses all of `sig/bc2cpp/declarations.rbs` |
| `Prism.lex` (with its token filter) | 1,122 | 1.3% | `RbsParamCheck.foreign_ruby_names` |

This page covers what those trees feed, which parses can be skipped on a warm
cache, and the two that now are.

## What the parses are used for

**`Prism.lex` in `RbsParamCheck.outside_call_names`.** Each foreign Ruby
source that the closed world does not compile (mruby's core and gem `mrblib`)
is tokenized. The result is the list of words that code outside the analysed
bytecode can use to call a method. That list depends only on the file's bytes
and the Prism version. Nothing else reads the tokens.

**`RBS::Parser` in `NativeSigs`.** `declarations.rbs` (451 KB, 12,706 lines)
holds the program hints and 43 native tables. In the Optcarrot compile, only
the native-table loaders read it: `NativeCoreResultSigs`, `CoreHierarchySigs`,
`CoreFactSigs`, `CoreBlockIteratorSigs`, `CoreBlockParamSigs`,
`CoreBlocklessIteratorSigs`, `NativeResultFacts` and `NativeConstructorSigs`.
They read 11 tables, about 22 KB of text in all. Each loader reads names,
types, overloads and annotations from `NativeSigs.decls(table)`. One check
also reads each block's marker comment. No loader reads a location.

**`Prism.parse` through `RubyParseCache`.** Logging every lookup in a warm
run shows the parses that remain (a miss is the first parse of a file):

| First parser (miss) | Files | Bytes | Later readers of the same tree |
| --- | ---: | ---: | --- |
| `DispatchTargetSources.class_initializers` | 25 | 2,606,012 | `ClassBodyScan`, `ClassWorld` |
| `ClassBodyScan.scan` (`mruby-lcf`) | 8 | 257,313 | `ClassWorld` |
| `PredicateReturns.violations_in` | 1 | 128,166 | `ConversionReturns` (keeps AST nodes in its results) |
| `compiled_gems.rb` gem walk | 17 | 113,637 | up to 8 foreign-Ruby scans |
| `foreign_method_owners` | 24 | 104,018 | `OutsideRubyIvarScopes`, `OutsideRubyOwners`, `ForeignDefiners`, `NativeSingletonCall` |
| `NativeConstructorSigs.ruby_initialize` | 5 | 94,276 | `ClassBodyScan`, `ClassWorld` |

Skipping a file's parse needs every reader of that file to come from a cache.
Caching only the first reader moves the parse to the next one. Most of the
cost is in `mruby-rpg2k`, which `dispatch_targets.rb` parses first. That file
is outside this change, so these Prism parses still run. A cache for one of
these files must cover `ClassBodyScan`, `ClassWorld` and the dispatch-target
scan together. [Prism readers in the scan cache](bc2cpp-prism-reader-cache.md)
does that.

**Prism's serialized form does not help.** `Prism.load` of a `Prism.dump`
allocates as many objects as `Prism.parse` (Prism 1.8.1):

| File | Bytes | `Prism.parse` objects | `Prism.load` objects |
| --- | ---: | ---: | ---: |
| `mruby-rpg2k/mrblib/scene/map.rb` | 628,576 | 55,851 | 59,360 |
| `mruby-rpg2k/mrblib/game.rb` | 526,566 | 50,367 | 51,405 |
| `mruby-lcf/mrblib/schema.rb` | 159,686 | 20,203 | 20,231 |

Most of the cost is building the Ruby node objects, not parsing the text. So
caching the derived facts is the only option that pays.

## What changed

- `RbsParamCheck.foreign_ruby_file_names(path)` stores each file's
  `foreign_ruby_names`, de-duplicated, in the scan cache. On a warm run the
  file is not lexed. Dropping repeated names does not change the result:
  `outside_call_names` adds each name and its stem to a Set, and the first
  occurrence has already added both.
- `NativeSigs.decls(table)` restricts a parse of the table's kept text instead
  of the whole file. The kept texts (`NativeSigs.kept_texts_of`) are one
  String per table, built in a single walk of the file. Each one holds the
  source lines of every block and member `restrict` keeps for that table,
  copied with their comments and with no markers added. The `{ table => text }`
  Hash, 326 KB for all 43 tables, is stored in the scan cache. A warm run parses about 22 KB of RBS
  instead of 451 KB. A cold run computes the texts from the whole-file parse,
  and both runs then follow the same path, so warm and cold give the same
  declarations. `NativeSigs.table_source`, the marker-annotated text that
  checks use as a fixture file, is unchanged.

## Cache-key soundness

Both entries use `ScanCache.fetch`. The key already includes the digest of
every `tools/bc2cpp` source, the Ruby version and the Marshal format. Each
entry also names its parser version: `rbs_param_check.foreign_ruby_names.prism<VERSION>`
and `native_sigs.kept_texts.rbs<VERSION>`. Each entry's only input is one
file: the foreign source, or `declarations.rbs`. The key includes that file's
SHA-256. A missing file is not cached (`cache_absent: false`), so it fails the
same way as before. The stored values are plain Strings, an Array of Strings,
or a Hash of Strings. Neither computation reads ENV.

Restricting the reparsed text gives the same result as restricting the whole
file because every kept node keeps its own comment and its enclosing blocks'
comments. So `table_of` reads the same markers. Every node that the text drops
is one that `restrict` drops anyway.
`scripts/bc2cpp/native_member_tables_check.rb` checks this for the fixture and
for all 43 tables of `declarations.rbs`. It compares `==`, the RBS JSON
without locations, and the comment of every node. If the block header starts
at the `class` line instead of its comment, the check fails.

## Evidence

Measurements used Ruby 4.0.5, the profiling `mrbc`, and the sealed Optcarrot
world. The baseline was master `1f5610856`, and only the two compiler files
differed. Each set alternated before and after runs in `--mode none`. Warm
runs used one fixed world path, and each version got one warm-up run first.
Cold runs deleted `build/bc2cpp-cache` before every run. Generated C++ was
byte-for-byte identical across all 12 fixed-path runs. In the `--optcarrot`
runs, which use a new temporary world each time, it differed only in the
world path, including the hex-escaped path strings.

| Cache | Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | --- | ---: | ---: | ---: | ---: |
| warm, fixed world | 1 | 8,400,641 | 7,986,528 | 7.653 | 7.398 |
| warm, fixed world | 2 | 8,400,683 | 7,986,631 | 7.783 | 7.390 |
| warm, fixed world | 3 | 8,400,568 | 7,986,611 | 7.704 | 7.560 |
| cold, fixed world | 1 | 9,371,452 | 9,360,820 | 9.460 | 9.221 |
| cold, fixed world | 2 | 9,371,516 | 9,360,846 | 9.316 | 9.096 |
| cold, fixed world | 3 | 9,371,308 | 9,360,844 | 9.052 | 10.105 |
| `--optcarrot` temp world | 1 | 9,206,350 | 8,796,421 | 8.779 | 8.674 |
| `--optcarrot` temp world | 2 | 9,206,279 | 8,796,467 | 8.175 | 8.604 |
| `--optcarrot` temp world | 3 | 9,206,308 | 8,796,453 | 8.537 | 8.762 |

- **Warm:** about 414,000 fewer allocations per compile (4.93%).
- **Cold:** about 10,600 fewer (0.11%). The single walk that builds the texts
  costs less than restricting the whole file for each loader.
- **`--optcarrot`:** about 410,000 fewer (4.45%). Both inputs have fixed
  paths, so this cache hits even when the world changes.

After the change, the warm object profile shows `RBS::Parser._parse_signature`
at 42 samples (was 1,882), and `Prism.lex` no longer appears. Timing varied
by more than the differences between versions, so these runs do **not** show
a speedup. The demonstrated result is the reduction in allocations.

After merging master `9c9ce0727`, one warm pair on the same fixed world gave
7,646,544 allocations before and 7,232,555 after (-413,989). The generated
C++ was byte-for-byte identical.
