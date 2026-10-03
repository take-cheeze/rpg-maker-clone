# 0315. bc2cpp: Go-style interface tables for polymorphic receivers, measured and not built

Date: 2026-10-02

## Status

Accepted (a decision not to build; revisit if a trigger below fires).
Superseded by [ADR 0328](0328-bc2cpp-generated-interface-tables.md), which builds
the tables opt-in for source size and lookup shape. The census below stays the
measured baseline; the removal goal it declined remains ADR 0323's work.

## Context

The request: for a call name `n` with receiver class set `S`, build a per-name "interface table" (itab), one cell per
implementing class, where a cell is a compiled Ruby body or a registered native/core C entry, so the call is a table
dispatch with a proven-dead else (`bc2cpp_nomethod`) instead of a class-compare chain whose else keeps a by-name
`bc2cpp_send`; and extend the `# bc2cpp:` annotations toward an RBS-style form if that fits.

ADR 0296 counted 746 `POLY_SMALL_N` sites with a non-error else (about 374 "by a core/native/singleton/opaque definer",
372 "by name") and 70 `POLY_TABLE` sites (`dynamic_install`). ADR 0210 and 0290 fix the rule any new proof obeys: a hint
is not a proof.

## Method

Wio closed world, master `43031b24` (ADRs 0307-0312 merged), shipped pass of `scripts/bc2cpp_coverage_report.rb`, all three
compiled gems, `3rd/*` populated. New, output-neutral tooling (`shipped.cxx` is byte-identical with it on):

- `BC2CPP_ITAB_REPORT=<tsv>` (`tools/bc2cpp/interface_table_report.rb`): one row per explicit-receiver send that has a guard
  chain, with the family, the else arm of the final code, **every** `ClosedWorld#refusal` gate the name fails (not only the
  first), the receiver's proven instance classes (`CodeGen#receiver_instances`) or the flow mask that fell short, its
  origin, the chain's listed classes, what each cell of a proven set would be, and the native registration facts of the
  name. `<tsv>.names` holds one row per method name (Ruby instance owners, singleton owners, native, outside name).
- `scripts/bc2cpp_interface_table_report.rb <tsv> [owner-regexp]` aggregates it.
- An unsound oracle (not in the tree): `refusal` told to ignore `dynamic_install`, `unknown_definer`, `core_or_native` and to
  require only the listed classes that are in `S`, whenever `S` is proven. It is an upper bound for any per-class proof.

"Dispatching" below means the final code of the site's else arm still reaches a by-name call (a `CLOSED_WORLD kept:`
marker or an unmarked funcall).

## Results

**ADR 0296's "372 kept by name" were not dispatching.** 409 `POLY_SMALL_N` sites (`no_dispatch`) have no else dispatch in
the final code; e.g. `Game::Actor#state_table` calls `LCF.field?(row, :name)` as a direct `CLOSED_WORLD_CONSTANT_OBJECT` call.
`GuardHintReport` labelled them `none` and the ADR summed them with the kept ones. The population is:

| family x else arm (5,730 sites with a chain) | sites |
| --- | ---: |
| `nomethod` else already (`POLY_SMALL_N` 2,196, `MONO_EMBED_GUARD` 1,204, `IVAR_ACCESSOR` 850, `TYPED` 122, `ELEMENT` 5) | 4,377 |
| no dispatch at all in the final code | 783 |
| **else still dispatches by name** | **570** (519 in `RPG2k*`/`Game*`, 51 elsewhere) |

### (a) Why the 570 else arms are kept

| why | sites | receiver set |
| --- | ---: | --- |
| `core_or_native`: a name spelled by a native or foreign Ruby anywhere (`ClosedWorld#outside_names`) | 276 | 21 proven, 255 unproven |
| `singleton_definer`: `Graphics.update` next to `window.update` | 154 | unproven |
| `dynamic_install`: `alias_method`/`def update` in a `class << Graphics` probe (`mruby-rgss/mrblib/lib.rb`), `sort`/`sort!` | 73 | 42 proven, 31 unproven |
| unmarked funcall (`send`, mostly core-compiled bodies and constant receivers) | 41 | unproven |
| `unlisted_class` (a definer the chain does not list) | 21 | unproven |
| `opaque_definer` (`LCF::File` family) | 5 | unproven |

**507 of 570 (89%) have a receiver class set the flow does not prove**, so no interface table can exist for them: 144 are an
incoming argument (class pool not admitted), 128 a call result outside the return table, 121 an `@ivar` (pool dropped),
59 a constant, 26 an indexed result, 18 a captured local. This is ADR 0296's "331 of 371" again, now 507 of 570.

**63 have a proven set.** Per site:

| name | sites | set | cell | gates failed |
| --- | ---: | --- | --- | --- |
| `update` (`@window`, `@interpreter`, viewports) | 42 | `RPG2k::Window` 23, `Game::Interpreter` 16, `RGSS::Viewport` 2, two `Scene::Battle` 1 | Ruby body, native direct entry, one body not direct-callable | `dynamic_install`, `unknown_definer`, `core_or_native`, `unlisted_class` |
| `include?` | 9 | `Array` | Ruby body (`mruby-rgss/mrblib/array_include.rb`) | `core_or_native`, `opaque_definer` (`Array` is a boot class) |
| `delete` | 9 | `Hash` 8, `Array` 1 | native `mrb_ary_delete` / Hash delete, no frame-independent entry | `core_or_native` |
| `count` | 2 | `Hash` + `MessageState` | native + ivar accessor | `core_or_native` |
| `start` | 1 | the two `Scene::Battle` classes | Ruby bodies (the name is also `GC.start`, `gc.c`) | `core_or_native` |

Native registrations behind `core_or_native` (arity, entry): `Symbol#name` `sym_name` (none), `Fiber#resume` `fiber_resume`
(any), `Array#delete` `mrb_ary_delete` (req 1), `String#count` `str_count` (req 1), `Array#at` `ary_at` (req 1), `Struct#to_h`
`mrb_struct_to_h` (none), `Array#index` `mrb_ary_index_m` (opt 1), `Array#shift` `mrb_ary_shift_m` (opt 1), RGSS `width`/`height`/
`update`/`dispose`/`flash` in `mruby-rgss/src/lib.cxx`. Frame-independent entries (what a table cell may call without
a call frame, because `mrb_get_args` reads the frame) exist for 11 audited core methods (`NativeCoreDirect`: `Array#join` 0/1,
`shift` 0, `compact`, `index` 1, `__svalue`, `to_a`, `Integer#inspect`, `String#size`, `length`, `bytes`) and 153 RGSS owner entries
over 92 names (`NativeDirect`). Neither has `Hash#delete`, `Array#delete`, `String#count`, `Array#include?`.

### (b) How many could become a cell with a sound proof

Of the 63, 51 have a cell that is a direct body, a native direct entry or an error; 11 have a native with no entry (the cell
would be a send: a relocation); 1 has a body that is not direct-callable. The refusal gates, not missing cells, are what
holds the 51: the oracle above converts 42 `update` sites, the `start` site, and 11 sites that it must not (Hash/Array `delete`,
`count`: the natives are real, so a nomethod there is wrong); `include?` stays (`opaque_definer`). Removing the install and
unknown gates for `update` alone (measured) changes **0** sites: `core_or_native` (outside Ruby spells `update`, so
`native_arms_lift?` refuses) and `unlisted_class` still hold. A sound slice therefore needs three new proofs together: (1) a
`DEF`/`alias_method` inside a `class << <class constant>` body defines on a class object, never on an instance of a proven set (ADR
0280/0302 give the instance side); (2) per-class native/outside-Ruby resolution (`ForeignDefiners.defines?` and
`NativeDirect.registered_owners` already answer it per owner; the registry's `<native>` owner has no class); (3) a cell check
against `S` instead of the name's whole definer set. **At most 42 sites** (41 `update`, 1 `start`), 1.5% of the 2,815 by-name
sends.

### (c) Per-name method-set sizes (3,645 names)

| Ruby instance owners per name | 0 | 1 | 2 | 3 | 4 | 5-8 | 9-16 | >=17 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| names | 1,206 | 2,190 | 176 | 35 | 24 | 10 | 2 | 2 |

249 names have two or more Ruby implementers, 36 of them also natively defined. 94% of the polymorphic names have four or fewer,
and the chains are short: `POLY_SMALL_N` lists 1 class at 1,372 sites, 2 at 566, 3 at 383, 4 at 183, 5-8 at 381, 9-13 at 12 and
16 (the cap) at 126; the 70 `POLY_TABLE` sites list 19 (ADR 0227: runtime-class lookup with a per-site memo, native-direct
arms in the else). The compare chain is the right shape for 2-4 classes (a pointer compare each, no load) and the table
already exists above 16. The 126 sites at the cap are the only place a table could beat a chain on speed; that is a
throughput question, not a removal one, and none of them is in the 570. Neither the shape nor the number of cells is the
cost: the else is.

### (d) Removal against relocation

| | sites |
| --- | ---: |
| else dispatches by name today | 570 |
| receiver set unproven (no table possible) | 507 |
| set proven, removable with three new proofs | at most 42 |
| set proven, cell is a native with no entry (send in a cell: relocation) | 11 |
| set proven, `Array` boot class / not direct-callable | 10 |

Oracle upper bound (all four name gates off for proven sets): `bc2cpp_send` 2,815 -> 2,762 (-53), of which 11 are unsound.

## Decision

**Not built.** Cutoff used: at least 40 sites removed. The ceiling is 42, reached only with three new proofs (singleton-body
definers, per-class native resolution, a cell check against `S`) in `closed_world.rb`/`codegen_send.rb`/`codegen_return_analysis.rb`,
each needing negative worlds and mutation tests, for a change that touches code other work is changing and removes 1.5% of the
by-name sends (most of them `@window.update`, a table lookup today). A cell that is a native function is not available
beyond 11 core and 153 RGSS audited entries, because a native called directly has no call frame for `mrb_get_args`.

The mechanism the request describes already exists in pieces: `POLY_SMALL_N` chains with `NATIVE_DIRECT` exact-class arms (ADR
0253/0263), `NATIVE_CORE_DIRECT` (0257), `UNLISTED_CLASS_GUARDS` (0252/0259), `POLY_TABLE` (0227). What keeps the else is the
receiver set (89%) and name-level gates, neither of which a table changes. `BC2CPP_INTERFACE_TABLES` is therefore not added.

## RBS-style annotations: they do not fit

Today (`tools/bc2cpp/annotations.rb`, 168 `# bc2cpp:` comments in the mrblib): one comment on the line above a `def`,
`# bc2cpp: (T, ...) -> R`. `Annotations` reads `fixnum`/`Integer`/`symbol`/`Symbol`/`Array` per argument and return (a wrong
claim raises `TypeError` at the embedded store); `ClassAnnotations` an exact class name per argument (a known owner,
`Array<K>`/`Hash<K>` as the container); `ElementAnnotations` `Array<K>` elements and `-> K` (exact class of the result); each
consumer keeps a runtime class guard with a send fallback (`TYPED`). `AnnotationContradictions` (RBS_SEED_CONTRADICTION)
turns a `fixnum` against `symbol` disagreement with an inferred type into a build error. It cannot say: a union, an interface,
nilable, an ivar, a block, or `self`.

A `interface _Drawable; def draw: (Bitmap) -> void; end` form would be a hint that must be verified at build time. The
verification needs the set of classes that reach the site, which is the proof that is missing for 89% of the kept sites; where
it exists (the 63) the annotation adds nothing, and where it does not the annotation can only stay a guarded hint, which is what
`TYPED` already is. What it could add is a **tripwire** (build error when the world later gains a class that violates the
declared interface), not removal. Not worth a reader plus a parser subset now; the cheaper step is to extend
`AnnotationContradictions` to class tokens once an arg-pool proof exists for the same parameter.

## Triggers to revisit

- The receiver-set coverage rises (constructor-argument pools, call-result facts): re-run the report; the proven share is the
  number that matters. At about 150 proven kept sites a per-class refusal pays.
- `mruby-rgss` stops redefining `update` in a `class << Graphics` probe (`lib.rb`); that alone is not enough (measured), but
  it is the cheapest of the three proofs to remove from the problem.
- A frame-independent `Hash#delete`/`Array#delete` entry is audited into `NativeCoreDirect`.

## Consequences

`BC2CPP_ITAB_REPORT` and `scripts/bc2cpp_interface_table_report.rb` are the reproducible census for the next attempt; they change
no generated code. Not run: the firmware smokes, the optcarrot (open-world) comparison, a 32-bit `mrb_int` or core-only run
(nothing in generated code changed).
