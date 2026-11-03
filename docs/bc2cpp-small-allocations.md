# Small allocation fixes in bc2cpp

A batch of mechanical changes that cut host objects the bc2cpp compiler
allocates without changing what it computes. Each item below is one commit.
The sites were picked from an object-mode profile of the sealed Optcarrot
compile (`scripts/bc2cpp/compiler_profile.rb --mode object --optcarrot`, see
[compiler data profiling](bc2cpp-compiler-data-profile.md)), with stackprof's
frame `:edges` naming the caller of each allocating leaf.

## 1. Stat each scanned source list once per compile

`ForeignDefiners.scan`, `OutsideRubyOwners.scan` and `NativeCoreDirect.audit`
keyed their memos on the `[path, mtime, size]` of every file and re-statted
every file on every call. `File.stat`, `File::Stat#mtime` and `File.file?` from
these three were about 2.4% of the object samples (2,205 of 93,678).

`FileIdentity` (tools/bc2cpp/file_identity.rb) now computes that key. The
bc2cpp command line calls `FileIdentity.sources_fixed!` before any work, and
from then on each path list's existing files and stat key are memoized for
the process. That rests on one assumption: **the sources a compile reads do
not change while it runs**. Loaded as a library (the `*_check.rb` harnesses)
the memo is off and every call stats afresh, so a check that rewrites a
fixture between scans still sees the rewrite (`foreign_definers_cache_check`
covers that).

## 2. Register names from a frozen table

`"r#{reg}"` allocates an `Integer#to_s` String for each interpolation
(2.7% of samples). `RegName[reg]` returns a frozen `"r0"` .. `"r255"` from a
table and falls back to `"r#{reg}"` for any other value, so it is the same text
for every input. The hot emitters interpolate it instead: `compile_insn_op` and
`compile_cmp` (codegen_insn.rb), `compile_send`, `outside_owner_call_line`,
`emit_register_initializers`, the POLY_SMALL_N call arm and
`TaggedFixnum.tier`. `receiver_loaded_self?` reads a register back through
`RegName.number`, a frozen-table lookup ahead of the old regexp.

The rewrite was textual: every `r#{X}` not preceded by an identifier character
became `#{RegName[X]}`. A Prism walk confirmed that each `#{RegName[` in the
edited files is a call inside an interpolation, so none landed in a
non-interpolating literal and every string keeps its text.

## 3. Collection and String churn

- **`inheriting_subclasses`** sorted every class name (`@superclass_of.keys.sort`)
  and built the definition-owner Set on each call, though most owners have no
  qualifying subclass. It now selects in hash order, builds the Set only when a
  strict subclass is found, and sorts the selection. The predicate is pure, so
  sorting the selected names gives the list the sorted-keys walk gave.
  `Array(nil)` checks of the mixin tables became `no_mixins?`, and
  `fetch(name, [])` defaults became `fetch(name) { [] }`.
- **`poly_diagnostic`** caches the formatted exclusion list instead of the
  reason counts it was formatted from.
- **`direct_call_args`** builds the unboxed argument list with `Array.new`
  instead of `each_with_index.map`, and collects the unboxed positions only
  when one exists. `native_arg_types(...).compact.empty?` became
  `all?(&:nil?)` (the elements are `:fixnum` or nil).
- **`strict_hint_wrap`** reused the line `strict_hint_fallback` had already
  built and discarded, tests `base.include?(dispatch)` before compiling the
  pattern (the pattern's suffix is optional, so it matches exactly where the
  dispatch text occurs), and gives `gsub` the one replacement string.
  `strict_hint_line` is a pure function of its arguments and the current
  source site, which `dynamic_dispatch_line` does not change.
- **`NativeDirect.strip_comments`** is called on the same native file text by
  several scans. It now memoizes the stripped text per encoding and text and
  returns a fresh copy each call, as the `gsub` did.
- **`JoinDominance`** holds only its irep, so `JoinDominance.for(irep)` hands
  out one per irep (an `ObjectSpace::WeakMap`; a collected one is rebuilt).
  The walk only calls it.

## Measurements

Object-mode profile after each commit, on the branch's original base
(`1f5610856`, before the IR query allocation change landed on master):

| Version | `allocated_objects` |
| --- | ---: |
| base | 9,389,750 |
| 1. stat once | 9,125,773 |
| 2. register names | 8,947,832 |
| 3. collection and String churn | 8,572,174 |

Sealed Optcarrot compile, `scripts/bc2cpp/compiler_profile.rb --mode none
--optcarrot` (Ruby 4.0.5 with YJIT), against master `9c9ce0727`: one warm-up
run and then three alternating runs per version on the same host:

| Run | Version | `allocated_objects` | `elapsed_seconds` |
| --- | --- | ---: | ---: |
| 1 | master | 8,452,169 | 8.023 |
| 1 | this change | 7,646,887 | 7.549 |
| 2 | master | 8,452,246 | 8.349 |
| 2 | this change | 7,646,944 | 7.721 |
| 3 | master | 8,452,118 | 8.265 |
| 3 | this change | 7,646,817 | 7.494 |

Allocations fell by about 805,300 objects per run (9.5%), with a spread of
under 130 objects within each version. Elapsed time was lower in all three
pairs (0.47 to 0.77 s), but three runs on a shared host are not enough to
claim a speedup.

The generated C++ and the compiler log of the two versions are identical once
the per-run temporary paths (the Optcarrot world, plain and hex-escaped in
string pools, and the conversion-signature directory) are normalized.

## Left alone

- `ScanCache.file_digest` and `NativeExpressionDevirt.read_source` /
  `class_registrations` still stat per call; together they were under 0.2% of
  samples.
- `codegen.rb`'s `native_arg_types` allocates a `[irep, position]` key per
  position; the positions Set would need another shape.
- Native C identifier scans, Prism/RBS parse caching and the BytecodeIR,
  InsnDecoder and checked-send files belong to other changes.
