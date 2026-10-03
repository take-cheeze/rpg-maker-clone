# bc2cpp baseline after ADRs 0307-0317 (2026-10-02)

One consistent measurement of the dynamic dispatch left in bc2cpp's generated C++, taken on a single tree after the
eleven PRs of ADRs 0307-0317 landed. Each of those PRs measured its own delta on a different master commit, so the
per-PR deltas overlap; here every number comes from the same tree, and the marginal contribution of each feature is
measured by turning its kill switch off on that tree.

* Tree: `origin/master` `cd86085f` (PR #1991 merged), wio closed world, `3rd/*` populated, host `mrbc` prebuilt,
  `LANG=C.UTF-8`. Later master commits (for example ADR 0320, EXT1/2/3 folding) are not in these numbers.
* Method: `docs/bc2cpp-dynamic-site-census.md` (`## Method`), plus one run per switch
  (`BC2CPP_<SWITCH>=0 MRBC=<host mrbc> BC2CPP_COVERAGE_KEEP_DIR=<dir> ruby scripts/bc2cpp_coverage_report.rb`, then
  `scripts/bc2cpp_dynamic_site_census.rb <dir>/shipped.cxx --tsv ...`). Two runs of one tree are byte-identical, and
  every debug report (`BC2CPP_ITAB_REPORT`, `_ESCAPE_REPORT`, `_ELEMENT_REPORT`, `_GUARD_HINT_REPORT`,
  `_REFINE_REPORT`, `_NUMERIC_ROOTS`, `_PROVABLE_ERROR_REPORT`, `_SEND_ROOT_REPORT`) left every count below unchanged
  (checked against the plain run). Only `BC2CPP_SEND_ROOT_REPORT` changes the generated text (its tags), and the same
  counts came out.
* Scopes: **all** = every compiled gem (engine plus mruby-core mrblib); **non-core** = functions named
  `RPG2k_|Game_|RGSS_|LCF_`; **rpg2k** = functions named `RPG2k_|Game_` (the engine proper).
* Counts are generated-code lines in method bodies (the helper region is excluded), counted per enclosing generated
  function. The scope split is mine (a function-name prefix); `scripts/bc2cpp_dynamic_site_census.rb` itself prints
  the all-gems numbers only, and those match: 2,603 / 401 / 28 / 4,380.

## 1. Totals (default switches)

| Measure | all | non-core | rpg2k |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites | 2,603 | 2,159 | 1,800 |
| `mrb_funcall*` | 28 | 2 | 0 |
| `mrb_funcall_with_block` | 401 | 303 | 277 |
| by-name sites in total (the three above) | 3,032 | 2,464 | 2,077 |
| `bc2cpp_nomethod` | 4,380 | 4,312 | 4,274 |
| `bc2cpp_nil_receiver` | 890 | 868 | 837 |
| `bc2cpp_guard_violation(` callers | 310 | 309 | 238 |
| `bc2cpp_slow_*` callers | 3,314 | 3,106 | 2,852 |
| `bc2cpp_getidx`/`getidx0` callers | 2,069 | 2,012 | 1,955 |
| `bc2cpp_setidx` callers | 209 | 191 | 184 |
| `bc2cpp_eqq` callers | 110 | 104 | 104 |
| reach sites (any line that can reach by-name dispatch: the first three rows, `slow_*`, `getidx*`, `setidx`, `eqq`) | 14,314 | 13,366 | 12,521 |

"Reach sites" is an upper bound on dynamic exposure: a `slow_*` helper holds a by-name call only for an operand class
it does not own (20 by-name calls in all the `slow_*` helpers together), and `getidx`/`setidx`/`eqq` reach one only
for a non-Array/Hash/Integer receiver. The directly dynamic sites are the three `by-name` rows (3,032 all, 2,077 rpg2k).

Other whole-program numbers (same run, all gems): 3,047 compiled entry points (2,507 from bytecode, 540 synthesized
accessor overrides), method-level coverage 99.5% (2,507 of 2,519 attempted), 21 `#error` markers, 448 `BLOCK_FALLBACK`
bodies, 616 direct `:new` constructor paths, 3,028 cached by-name sites including guarded fallbacks, 896 POLY-marked
sites (594 engine, 302 compiled core), generated `shipped.cxx` 443,754 lines.

### Dispatch families (chains emitted in the shipped C++ / by-name sites that remain in that family)

| Family | chains, all | chains, rpg2k | by-name sites left, rpg2k |
| --- | ---: | ---: | ---: |
| `POLY_SMALL_N` | 2,461 | 2,363 | 233 |
| `MONO_EMBED_GUARD` | 1,061 | 1,059 | 16 |
| `IVAR_ACCESSOR` | 1,131 | 1,126 | 79 |
| `TYPED` (guarded, send fallback) | 70 | 68 | 34 |
| `EXACT_TYPED` (guard-free) | 420 | 420 | (no dispatch) |
| `ELEMENT` | 7 | 7 | 2 |
| `POLY_TABLE` | 76 | 58 | (dynamic-install else, see 3) |

Chains are `// FAMILY` marker lines; "by-name sites left" are the 1,800 rpg2k `bc2cpp_send` sites bucketed by the
nearest preceding family marker, so a site counts in one family only. The rest of the 1,800: `NONE` 296,
`NATIVE_CORE_DIRECT` 250, `NATIVE_DIRECT` 157, `POLY` 114, `CLOSED_WORLD_STABLE_CLASS` 108, `INDEX_EXACT` 100,
`MONO` 84, `RGSS` 58, `ARRAY_PUSH` 32.

### Kept else arms, interface tables, shipped by-name classes (ADR 0315, 0317)

* Explicit-receiver sends with a guard chain (rpg2k and Game owners): 5,618. By final else arm: `nomethod` 4,399,
  no dispatch left 766, **453 still dispatch by name** (419 kept else, 34
  `send`).
* Kept-else sites in the engine gems (`refine` report): **375** with the facts on, 438 with `BC2CPP_CALL_FACTS=0`
  (the 63 difference is the whole of CALL_FACTS's effect on the `bc2cpp_send` total). The "462 -> 399 kept else
  arms" in the ADR 0317 table counts generated lines, a different unit.
* Of the 453 by-name sites, 53 have a proven receiver class set and 400 do not.
* Census category (rpg2k, 1,800 sites; exclusive): `core_tag_chain_else:receiver_other` 669, `rgss_native_exact_class_else`
  276, `core_tag_chain_else:receiver_is_ivar` 191, `closed_world_kept:core_or_native` 176, `closed_world_kept:singleton_definer`
  99, `other:numeric_tag_guard` 85, `other:no_guard_nearby` 64, `poly_diag:dynamic_single_registered_definition/receiver_class_unresolved`
  62, `closed_world_kept:dynamic_install` 59, `known_class_arm_still_by_name` 34, `owner_chain_default_else` 25.
  Most of the first four are else arms of a guard chain that still has to exist (a receiver whose class the flow
  does not prove), not sites that have no chain.

## 2. Marginal contribution of each landed feature

Each row is a full rebuild of the same tree with one switch set to `0`. The value is the metric with the switch OFF
and the delta against master in parentheses; **the feature's own contribution is the opposite sign of the delta**
(CALL_FACTS: master has 63 fewer `bc2cpp_send` than with it off). Scope: all gems, then rpg2k in the second table.
Build durations (`bc2cpp_coverage_report.rb` plus census): 224-314 s per run (about 4 min), 457 s with all debug
reports on, no failure except one SIGTERM (see 6).

### all gems

| switch off (ADR) | `bc2cpp_send` | `mrb_funcall_with_block` | `bc2cpp_nomethod` | `nil_receiver` | `slow_*` | `getidx` | `setidx` | reach sites | `shipped.cxx` lines |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **master** | 2,603 | 401 | 4,380 | 890 | 3,314 | 2,069 | 209 | 14,314 | 443,754 |
| `CALL_FACTS` (0317) | 2,666 (+63) | 401 | 4,318 (-62) | 890 | 3,314 | 2,069 | 209 | 14,315 (+1) | 443,919 (+165) |
| `CONSTRUCTOR_POOLS` (0313) | 2,604 (+1) | 401 | 4,372 (-8) | 890 | 3,314 | 2,094 (+25) | 209 | 14,332 (+18) | 443,726 (-28) |
| `ESCAPE_ANALYSIS` (0316) | 2,600 (-3) | 400 (-1) | 4,380 | 890 | 3,309 (-5) | 2,066 (-3) | 209 | 14,302 (-12) | 443,374 (-380) |
| `CORE_EXTEND` (0314) | 2,684 (+81) | 401 | 4,380 | 890 | 3,314 | 2,069 | 209 | 14,395 (+81) | 443,684 (-70) |
| `TUPLE_RETURNS` (0311) | 2,603 | 401 | 4,380 | 890 | 3,355 (+41) | 2,069 | 209 | 14,355 (+41) | 443,886 (+132) |
| `RETURN_ACCESSORS` (0309) | 2,616 (+13) | 402 (+1) | 4,429 (+49) | 881 (-9) | 3,314 | 2,105 (+36) | 219 (+10) | 14,414 (+100) | 444,187 (+433) |
| `EXACT_CORE_ARMS` (0309) | 2,659 (+56) | 401 | 4,380 | 884 (-6) | 3,470 (+156) | 2,069 | 209 | 14,520 (+206) | 445,040 (+1,286) |
| `EXACT_NATIVE_WRAPPERS` (0307) | 2,812 (+209) | 401 | 4,424 (+44) | 809 (-81) | 3,314 | 2,069 | 209 | 14,486 (+172) | 446,644 (+2,890) |
| `BLOCK_ARM_REACH` (0310) | 2,603 | 449 (+48) | 4,380 | 884 (-6) | 3,314 | 2,069 | 209 | 14,356 (+42) | 443,646 (-108) |
| `CAPTURED_LOCAL_CLASS` (0308) | 2,665 (+62) | 407 (+6) | 4,382 (+2) | 888 (-2) | 3,415 (+101) | 2,090 (+21) | 241 (+32) | 14,536 (+222) | 444,954 (+1,200) |
| `BLOCK_CORE_DIRECT` | 2,603 | 449 (+48) | 4,380 | 884 (-6) | 3,314 | 2,069 | 209 | 14,356 (+42) | 440,147 (-3,607) |
| `FROZEN_TABLES` (0306) | 2,603 | 401 | 4,380 | 890 | 3,320 (+6) | 2,069 | 209 | 14,320 (+6) | 443,766 (+12) |

### rpg2k (`RPG2k_|Game_` functions)

| switch off | `bc2cpp_send` | `mrb_funcall_with_block` | `bc2cpp_nomethod` | `nil_receiver` | `slow_*` | `getidx` | `setidx` | reach sites |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **master** | 1,800 | 277 | 4,274 | 837 | 2,852 | 1,955 | 184 | 12,521 |
| `CALL_FACTS` | 1,863 (+63) | 277 | 4,212 (-62) | 837 | 2,852 | 1,955 | 184 | 12,522 (+1) |
| `CONSTRUCTOR_POOLS` | 1,802 (+2) | 277 | 4,266 (-8) | 837 | 2,852 | 1,979 (+24) | 184 | 12,539 (+18) |
| `ESCAPE_ANALYSIS` | 1,800 | 277 | 4,274 | 837 | 2,852 | 1,955 | 184 | 12,521 |
| `CORE_EXTEND` | 1,881 (+81) | 277 | 4,274 | 837 | 2,852 | 1,955 | 184 | 12,602 (+81) |
| `TUPLE_RETURNS` | 1,800 | 277 | 4,274 | 837 | 2,893 (+41) | 1,955 | 184 | 12,562 (+41) |
| `RETURN_ACCESSORS` | 1,813 (+13) | 278 (+1) | 4,323 (+49) | 828 (-9) | 2,852 | 1,991 (+36) | 194 (+10) | 12,621 (+100) |
| `EXACT_CORE_ARMS` | 1,849 (+49) | 277 | 4,274 | 831 (-6) | 2,998 (+146) | 1,955 | 184 | 12,710 (+189) |
| `EXACT_NATIVE_WRAPPERS` | 1,987 (+187) | 277 | 4,305 (+31) | 756 (-81) | 2,852 | 1,955 | 184 | 12,658 (+137) |
| `BLOCK_ARM_REACH` | 1,800 | 325 (+48) | 4,274 | 831 (-6) | 2,852 | 1,955 | 184 | 12,563 (+42) |
| `CAPTURED_LOCAL_CLASS` | 1,857 (+57) | 283 (+6) | 4,276 (+2) | 835 (-2) | 2,951 (+99) | 1,976 (+21) | 215 (+31) | 12,735 (+214) |
| `BLOCK_CORE_DIRECT` | 1,800 | 325 (+48) | 4,274 | 831 (-6) | 2,852 | 1,955 | 184 | 12,563 (+42) |
| `FROZEN_TABLES` | 1,800 | 277 | 4,274 | 837 | 2,858 (+6) | 1,955 | 184 | 12,527 (+6) |

### What the switches do on the family counts (all gems; chains / rpg2k by-name sites left)

| switch off | `POLY_SMALL_N` chains | `IVAR_ACCESSOR` chains | `TYPED` chains | `EXACT_TYPED` chains | cached by-name sites (all) | rpg2k by-name sites left in `POLY_SMALL_N` / `NONE` / `RGSS` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **master** | 2,461 | 1,131 | 70 | 420 | 3,028 | 233 / 296 / 58 |
| `CALL_FACTS` | 2,461 | 1,131 | 70 | 420 | 3,091 | 291 (+58) / 296 / 58 |
| `CONSTRUCTOR_POOLS` | 2,461 | 1,131 | 72 | 418 | 3,029 | 233 / 299 / 58 |
| `CORE_EXTEND` | 2,461 | 1,131 | 70 | 420 | 3,109 | 233 / 376 (+80) / 58 |
| `RETURN_ACCESSORS` | 2,486 | 1,112 | 88 | 400 | 3,042 | 238 / 301 / 58 |
| `EXACT_CORE_ARMS` | 2,461 | 1,131 | 81 | 409 | 3,084 | 233 / 296 / 58 (`TYPED` left 45, +11) |
| `EXACT_NATIVE_WRAPPERS` | 2,505 | 1,131 | 70 | 420 | 3,237 | 233 / 296 / 245 (+187) |
| `CAPTURED_LOCAL_CLASS` | 2,474 | 1,129 | 70 | 420 | 3,096 | 243 / 300 / 87 (+29) |
| `BLOCK_ARM_REACH`, `BLOCK_CORE_DIRECT` | 2,461 | 1,131 | 70 | 420 | 3,076 | 233 / 296 / 58 |
| `TUPLE_RETURNS`, `ESCAPE_ANALYSIS`, `FROZEN_TABLES` | 2,461 | 1,131 | 70 | 420 | 3,028 / 3,024 / 3,028 | 233 / 296 / 58 |

### Reading the marginal table (these resolve the overlap)

* **By-name sends removed on this tree, by feature** (rpg2k in parentheses): `EXACT_NATIVE_WRAPPERS` 209 (187),
  `CORE_EXTEND` 81 (81), `CALL_FACTS` 63 (63), `CAPTURED_LOCAL_CLASS` 62 (57), `EXACT_CORE_ARMS` 56 (49),
  `RETURN_ACCESSORS` 13 (13), `CONSTRUCTOR_POOLS` 1 (2). The sum is 485; features can overlap (a site one feature
  fixes cannot be fixed again), so the sum is an upper bound on their joint effect. I did not run all switches off
  together.
* **Block sends**: `BLOCK_ARM_REACH` removes 48 `mrb_funcall_with_block` sites and adds nothing else, and
  `BLOCK_CORE_DIRECT=0` gives the identical counts: ADR 0310's reach is conditional on the block-core-direct arms, so
  the "48" cannot be credited to ADR 0310 alone. `CAPTURED_LOCAL_CLASS` removes 6 more.
* **`nomethod` moves with the by-name count.** A site that stops dispatching by name usually turns into a
  `bc2cpp_nomethod` else (`CALL_FACTS` -63 sends, +62 nomethod; `RETURN_ACCESSORS` -13 sends, +49 nomethod). Total
  by-name sends is therefore the right unit for dispatch, `nomethod` is not.
* **Wins that are not by-name sends**: `EXACT_CORE_ARMS` removes 156 `slow_*` callers and `CAPTURED_LOCAL_CLASS` 101
  (numeric operands now proven), `TUPLE_RETURNS` 41, `CONSTRUCTOR_POOLS` 25 and `RETURN_ACCESSORS` 36 `getidx`
  callers, `CAPTURED_LOCAL_CLASS` 32 `setidx`, `EXACT_NATIVE_WRAPPERS` removes 81 `nil_receiver` arms and trades
  2,890 lines of C++ for 209 sends.
* **`ESCAPE_ANALYSIS` is neutral on the engine**: 0 change in the rpg2k scope, and the all-gems -3 sends are the
  compiled-core `Array#combination` that compiles only with `BLOCK_FALLBACK_PROVEN` (one more compiled entry point,
  one more BLOCK_FALLBACK body, 3,046 -> 3,047). It is infrastructure for a later consumer.
* **`FROZEN_TABLES`** is worth 6 `slow_*` callers.
* `shipped.cxx` size: `BLOCK_CORE_DIRECT` costs 3,607 lines, `EXACT_NATIVE_WRAPPERS` 2,890, `EXACT_CORE_ARMS` 1,286,
  `CAPTURED_LOCAL_CLASS` 1,200.

## 3. Where the remaining by-name sites come from

### Receiver origin of the 1,800 rpg2k by-name sites (`BC2CPP_SEND_ROOT_REPORT`, 1,598 joined to a producer row)

| Producer of the receiver | sites |
| --- | ---: |
| call result (`send`) | 432 |
| ivar | 380 |
| incoming argument | 237 |
| `GETIDX` element | 200 |
| constant (`getconst`) | 162 |
| captured local | 43 |
| `loadnil` | 33 |
| Array literal | 20 |
| implicit self (skipped) | 16 |
| `aref` / string / range / arithmetic / keyword | 15 / 11 / 7 / 7 / 2 |
| unattributed (no row for the tag) | 202 |

Top call-result producers and why their class is not proven: `actors` 24 (candidate dropped, `Game::Party`), `map` 24
(spelled by a foreign Ruby/native source), `new(Sprite)` 24 (constructor not fully visible), `contents` 20 (aliased),
`to_s` 18 (foreign spelling), `teleport_targets` 16, `vehicle` 16, `keys` 15 (not fully visible), `parameters` 14
(native only), `reject` 13 (no definition). Ivar producers: `RPG2k::Scene::Map @interpreter` 24 (pooled, still by
name for its consumer), `Game::Interpreter @list` 22, `DebugMenu @contents` 21 (poisoned), `Map @state` 21,
`Game::Party @actors` 15. Why the ivar class pools are missing (rows over all ivar producers): failed 223, pooled 84,
structural poisoned 57, open 8, structural writer 8. 680 class pools were dropped in the matching families.

Receivers the flow proves completely that still go by name (consumer's own reasons): `RPG2k::Window` 22 and
`Game::Interpreter` (+nil) 16 (both `dynamic_install`), `RGSS::Sprite` 12+11+6, `RNG` 7.

Element reads (`BC2CPP_ELEMENT_REPORT`, 15,348 sites reach a by-name call, 1,151 read an element): container is an
ivar 380 (of which `@ui` 145, `@list` 45, `@db` 38), parameter or block parameter 231, nested element 151,
implicit-self call result 112, call result 106, captured local 72, fresh literal 48, unanalysable 44, constant 18.
Only 5 of 36 ivar containers have every creation and write classed (28 sites).

### Why the 453 still-dispatching sites are kept (`BC2CPP_ITAB_REPORT`, rpg2k and Game owners)

| Kept reason (first failing gate) | sites | receiver set proven / unproven |
| --- | ---: | ---: |
| `core_or_native` | 196 | 11 / 185 |
| `singleton_definer` | 141 | 0 / 141 |
| `dynamic_install` | 59 | 42 / 17 |
| `unlisted_class` | 21 | 0 / 21 |
| `opaque_definer` | 2 | 0 / 2 |
| `send` (no chain else, plain dispatch) | 34 | 0 / 34 |

Every gate a site fails (a site counts once per gate, over the 453 sites): `core_or_native` 403 (402 of the 419
kept-else sites), `singleton_definer` 193, `unlisted_class` 114, `dynamic_install` 59, `unknown_definer` 56,
`no_closed_world` 33, `opaque_definer` 24. By gate combination: `core_or_native` + `singleton_definer` 166, `core_or_native` alone 88 (81
unproven, 6 proven `Hash#delete`, 1 other proven), `core_or_native` + `unlisted_class` 70, `dynamic_install,unknown_definer,
core_or_native,unlisted_class` 42, `core_or_native` + `opaque_definer` 19, `dynamic_install,unknown_definer,
core_or_native,singleton_definer` 14, `singleton_definer` alone 13, `unlisted_class` alone 2, `opaque_definer` alone 2.

Proven versus unproven: 53 of 453 have a proven receiver set (42 `update` on `RPG2k::Window`/`Game::Interpreter` with
a `dynamic_install` definer, 6 `Hash#delete`, 5 other); 400 do not. Receiver origin of the unproven kept sites:
incoming argument 93, `get_ivar` 113 (73 `OTHER`, 32 unmodelled, 8 NIL|OTHER), `send_result` 101, constant 43,
`indexed_result` 18, captured upvar 18, literal container 5 (391 of the 400 have a flow-mask row).

Names of the kept sites: `core_or_native`: `name` 37, `include?` 19, `map` 17, `string` 15, `delete` 15 (+6 proven `Hash#delete`), `to_h` 13, `resume`
11, `at` 10, `flash` 7; `singleton_definer`: `width` 98, `height` 30 (128 of 141); `dynamic_install`: `update` 56, `sort` 3;
`unlisted_class`: `dispose` 19.

### Block sends with no compiled callee (rpg2k)

277 `mrb_funcall_with_block` sites: `each` 94, `each_with_index` 38, `map` 32, `any?` 15, `select` 15, `reject` 12, `new` 10
(`Array.new` / `Hash.new` with a block), `section` 9, `times` 9, `each_index` 8, `loop` 6, `open` 4, `reduce` 4,
`sort_by` 4, `index` 3, `each_with_object` 2, `find` 2, `sort` 2, `delete_if` 1, `downto` 1. Of the whole-program
literal-block sends, 402 call the compiled body directly (372 through exact-class core arms that keep the dynamic
send as their else) and 46 are dynamic only. 35 have a `BLOCK_FALLBACK` marker within six lines (the block is built as an RProc) and
4 an `EXPLICIT_BLOCK_ARG` marker (a rough text match, not a classification).

### Escape analysis (`BC2CPP_ESCAPE_REPORT`, ADR 0316)

Methods that ship: 4,114 creation sites. Engine: Array 850 (46 confined), Hash 355 (42), String 1,413 (742),
object 564 (3), block 669 (225), lambda 3 (1). 466 BLOCK_FALLBACK regions, 109 provably confined; block callees by RProc
sites / confined: `each` 206/38, `map` 44/0, `each_with_index` 44/0, `times` 10/10, `any?` 23/0. Constructors whose
`self` does not leave: 51 of 82. The census-wide totals (all irep) are 6,440 creation sites.

### Provable errors, interface lint, numeric roots

* `BC2CPP_PROVABLE_ERROR_REPORT` (ADR 0317): 0 provable errors in the three engine gems (rpg2k: 2,753 proven, 8,692
  unproven sends; mruby-lcf has one `undefined_name` row).
* Forward interface (sound): 37 by-name sites with an unproven receiver would lose their else (34 `nomethod`, 2 bare
  dispatch, 1 kept else); 1 kept-else removal in all. Backward interface (unsound upper bound): 114 sites, 53 kept-else.
  One possible bug (lint candidate): `LCF#encode -> to_lcf` at `mruby-lcf/mrblib/lcf.rb:505` (interface
  `&,is_a?,map,pack,to_lcf` and no listed class satisfies it; a branch may test the class first, so not proven).
* `POLY_SMALL_N` chains with two classes on one definition: 50 of 1,525 (177 of 8,906 compares).
* `BC2CPP_NUMERIC_ROOTS`: 2,650 guarded numeric operator sites with an unproven operand plus 123 tuple-return rows.
  These guard `slow_*` helpers, not by-name sends. Leaves of those operands: call results 2,955, parameters 1,929,
  ivars 966, `GETIDX` 750, operators 577, constants 321, aref 227, captured 148; reasons: untracked 3,152,
  dropped 1,163, flowfail 608, native 344, ret 252, multidef 197, arity 186.

## 4. Next levers, ranked

Counts are exact sites in the tables above (rpg2k scope unless stated). "Removable" means the else arm becomes a
`nomethod`/exact call once every failing gate is lifted; it is not a measured result of an implementation.

| Rank | Lever | Sites | Cheap? | Notes |
| ---: | --- | ---: | --- | --- |
| 1 | per-class native arms for `core_or_native`-bounded kept else (a class-id arm for the core/native definers, as the exact-wrapper arms do for RGSS) | 402 sites fail this gate; 88 fail only it | medium | unlocks the rest only with the other gates |
| 2 | the same, together with the `singleton_definer` gate (a definer inside `class << <class>` / `def self.x` is a class-object definer; the `width` and `height` sites fail it) | `core_or_native`+`singleton_definer` 166, `singleton_definer` alone 13 (`width` 98, `height` 30) | medium | the `width`/`height` rows need the native arm too |
| 3 | `core_or_native` + `unlisted_class` (`dispose` 19 and the `RGSS` unlisted classes) | 70 + `unlisted_class` alone 2 | medium | needs the native-arm lever first |
| 4 | restructure the `class << Graphics` probe (`mruby-rgss/mrblib/lib.rb:136-148`, an `alias_method` swap of `update`) so it is not a dynamic install | 56 `update` sites fail `dynamic_install` (42 with a proven set: `RPG2k::Window` 23, `Game::Interpreter` 16) | cheap code change, 0 sites alone | every one of them also fails `core_or_native` (and the 42 proven also `unlisted_class`, `unknown_definer`), so it pays only after levers 1 and 3 |
| 5 | Array.new / Hash.new with a block as a compiled block call | 10 `new` block sends | cheap | exact count, receiver class split not measured |
| 6 | SENDB receiver facts so the post-call facts see the receiver of a block send | 277 block sends (`each` 94, `each_with_index` 38, `map` 32) | medium | only a share has a proven receiver; not measured |
| 7 | numeric constants for `Bitmap.new` | 35 `new(Bitmap)` producer rows (all irep, not joined to shipped) | cheap | about 40% of unjoined `new(Sprite)` rows ship; shipped count not measured |
| 8 | `Hash#delete` / `Array#delete` native entries | 21 `delete` sites in `core_or_native` (6 with a proven `Hash` set) | cheap | the 6 are the only proven-set kept sites besides `update` |
| 9 | constructor-argument pools for ivars (ADR 0309's first blocker) | ~99 of the 225 unpooled ivar receivers (ADR 0309 figure, master `2b317417`) | medium | not remeasured here |
| 10 | foreign-spelling / not-fully-visible call results (`map` 24, `to_s` 18, `name` 10, `new(Sprite)` 24, `contents` 20 aliased) | 96 listed producers | blocked | missing proof (a foreign Ruby or native source defines the name) |
| - | EXT1/2/3 prefix folding | - | landed after this baseline (ADR 0320, PR #1992, master `b1ab8310`) | numbers here predate it |

If levers 1-3 land: 88 + 166 + 13 + 70 + 2 = at most 339 of the 419 kept-else sites (the combinations are exclusive),
and only if no other gate is left. The 400 unproven receiver sets
stay unproven; none of these levers is a receiver-class proof.

## 5. CI shard timing (last green master runs)

Job wall time in minutes (`started_at` to `completed_at`, queueing excluded), from the Actions API.
`bc2cpp-checks` and `bc2cpp-width` have `timeout-minutes: 45`.

| Shard | 56b14771 | 147fe7e6 | 420c7252 | cd86085f |
| --- | ---: | ---: | ---: | ---: |
| core-tables | 29.0 | 28.9 | 29.8 | **29.7** |
| fast | 20.0 | 16.0 | 17.5 | 21.9 |
| core-exact-direct | - | 16.1 | 18.8 | 19.8 |
| core-mrbtest | 15.4 | 23.2 | 17.6 | 17.8 |
| bc2cpp-width (int32) | 7.4 | 14.2 | 18.8 | 16.2 |
| call-results | - | 10.6 | 15.2 | 15.2 |
| block-arm-reach | 11.3 | 13.4 | 14.4 | 14.7 |
| core-flow | 9.5 | 14.7 | 9.6 | 13.3 |
| call-facts | - | - | - | 11.9 |

Other `cd86085f` shards: escape-analysis 10.5, constructor-pools 8.5, core-mutants 7.4, captured-locals 7.2, hot-only 6.7,
bc2cpp-build 4.9; everything else is under 6.

`core-tables` is 29-30 minutes (its "Run core-tables checks" step is 27.8 of the 29.7), not the 24.5 minutes quoted
earlier, and has been flat since `56b14771`. It is the only shard above 25 minutes and has about 15 minutes of headroom
to the 45-minute timeout; `fast` (21.9) is the next. Whole-run wall time is bounded by `core-tables` plus setup. The
per-check timing table of that job could not be read: the job log is served from a host the sandbox proxy does not
reach, and the log tool returned only the last lines.

## 6. Tool problems found

* `BC2CPP_SITE_PROFILE=<dir>` makes `scripts/bc2cpp_coverage_report.rb` abort (`POLY markers exceed dispatch sites`,
  exit 1): the profile instrumentation rewrites sends, so the report's own sanity check fires. The documented use is the
  optcarrot-probe workflow (a built binary writes hits), not the coverage report. The static `sites.tsv` it wrote
  before aborting is not used here. `site_rank` / executed-count ranking needs a workload binary, so the hit ranking
  is **not re-measured** in this baseline (the existing ranking section of the census doc is from an older master).
* One run (`BC2CPP_FROZEN_TABLES=0`) was killed with exit 143 after 106 s in the first pass (container restart, not a
  code failure); the rerun passed and is the number shown.
* `BC2CPP_SEND_ROOT_REPORT` joins 1,598 of the 1,800 rpg2k sites (202 untagged); its call-result table prints only the
  top 30 producers and needs the (deleted) `shipped.cxx` to re-join, so per-producer counts below the top 30 are
  unjoined all-irep rows.
* `scripts/bc2cpp_dynamic_site_census.rb` prints all-gems numbers only and does not count `getidx`/`setidx`/`guard_violation`
  or per-family chains per scope; the scope split and the family chain counts here come from a throwaway scan of the
  same `shipped.cxx` (function-name prefix), kept out of the repository (no new tooling in this PR).
* `docs/bc2cpp-dynamic-site-census.md` ADR 0317 table says "kept else arms 462 -> 399"; the refine report's kept-else
  site count is 438 -> 375. They differ in unit (generated lines versus sites); both are correct for their unit.
* CHECKS that fail identically on clean master in this environment (class_pools, eqq_direct, io_puts_model,
  def_deletion_safety, resumable, lcf_row_flow, numeric_slow, closed_world, computed_send, unlisted_class_call,
  frozen_tables, singleton_arity) were not run; the census scripts are what this page needs.
* `core-tables` at 29.7 minutes contradicts the "about 24.5 minutes" figure in the task brief; the Actions API is the source here.

## Not measured

* Hit-count ranking (needs a workload binary), the joint effect of all switches off together, the per-check CI timing
  table, and shipped-joined counts for producers below the top 30. The one-at-a-time deltas are exact for each switch
  on this tree; their sum is not the joint effect.
