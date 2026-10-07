# bc2cpp dynamic-dispatch site census

How much by-name dispatch is left in the C++ that bc2cpp generates for the wio
closed world, why each site is still dynamic, and what proof would remove it.
`scripts/bc2cpp_dynamic_site_census.rb` reproduces every number below from the
generated C++.

## Method

```sh
mkdir -p /tmp/keep
MRBC=<host mrbc> BC2CPP_COVERAGE_KEEP_DIR=/tmp/keep ruby scripts/bc2cpp_coverage_report.rb > /dev/null
ruby scripts/bc2cpp_dynamic_site_census.rb /tmp/keep/shipped.cxx [--tsv sites.tsv]
```

`shipped.cxx` is the `SKIP_UNSUPPORTED=1` pass of the whole-program wio build
(all three compiled gems, the shipped set). Two runs of the same tree are
byte-identical, so counts are comparable across revisions.

* **Call site**: one source line in a generated method body that calls
  `bc2cpp_send(M, recv, <index>, ...)`. The `<index>` is mapped back to a method
  name through `bc2cpp_sym_names`. The helper definitions are not counted.
* **Helper region**: everything before the first generated `*_impl` body. A
  by-name call there is *held by a helper*; it is reached from every generated
  site that calls the helper.
* Each site is classified by (a) its position (inside a known-class arm, in the
  else arm of an inline fast path, or bare), (b) the nearest preceding marker
  comment, (c) the `POLY_DIAG` line when the site has one, and (d) a heuristic
  for where the receiver register was last assigned.
* The categories in the "why" table are exclusive; the first matching rule wins
  (see `category` in the script).
* `--tsv` writes one row per body site (line, owner method, name, arity, fast-path
  flag or `class_arm`, marker family, guard shape, receiver origin, category,
  `POLY_DIAG` path). The owner tables are a grouping of the owner method's
  prefix; the "Now" numbers below were produced this way from `0a9adfc`.

## Results (master at `0a9adfc`)

The previous snapshot of this section was master `f70fef67` (PRs #1947-#1962
merged, 9,733 `bc2cpp_send` lines before that round); the follow-ups below
carry the ADRs that landed since. "Then" is that snapshot, "Now" is a fresh run
of the census on the shipped set of `0a9adfc` (`shipped.cxx`, 441,136 lines,
helper region lines 1..22,574).

| Measure | Then (`f70fef67`) | Now (`0a9adfc`) | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 5,081 | 2,325 | -2,756 (-54.2%) |
| `bc2cpp_send` calls held in helpers | 24 | 24 | 0 |
| **`bc2cpp_send` total (what a text count sees)** | **5,105** | **2,349** | **-2,756 (-54.0%)** |
| `mrb_funcall_with_block` sites (`BLOCK_FALLBACK` markers 447 then, 462 now) | 448 | 417 | -31 |
| `mrb_funcall` / `_argv` / `_id` in bodies | 28 | 30 | +2 |
| `mrb_funcall*` held in helpers | 5 | 5 | 0 |
| `bc2cpp_nomethod` sites (error raise, not dispatch) | 4,562 | 4,460 | -102 |

The helper-held `mrb_funcall*` are not dispatch in the shipped build: two sit
under `#ifdef MRB_UTF8_STRING` (String#size/length, ADR 0291; the project does
not define it) and one is the `puts` of the guard-violation error path. The
helper region also holds one `mrb_yield_argv`.

### Relocated into helpers versus removed

A text count overstates a win whenever a by-name call moved into a shared
helper. Counting the generated sites that can still reach a by-name call (their
own `bc2cpp_send`, plus every call into a helper whose slow arm dispatches by
name, plus the block and funcall sites):

| | Then | Now |
| --- | ---: | ---: |
| Own `bc2cpp_send` in bodies | 5,081 | 2,325 |
| Calls into `bc2cpp_slow_*` (ADR 0292) | 3,542 | 3,274 |
| Calls into `bc2cpp_eqq` (ADR 0293) | 110 | 110 |
| Calls into `bc2cpp_getidx` / `getidx0` / `setidx` | 2,584 | 2,397 |
| `mrb_funcall_with_block` + body `mrb_funcall*` | 476 | 447 |
| **Sites that can reach by-name dispatch** | **11,793** | **8,553** |

* Of the net -3,240, -2,756 are removed `bc2cpp_send` sites in bodies. The rest
  is callers that stopped reaching a helper: 268 `slow_*`, 187 index-helper
  callers (2,584 to 2,397) and 29 block or funcall sites.
* The shared helpers still hold by-name calls that thousands of generated sites
  reach (`getidx` 2,017 callers, `slow_add_f` 712, `slow_sub_f` 471,
  `slow_mul_f` 442, `setidx` 348, `slow_gt` 311, `slow_lt` 296, `slow_div` 272).
  The numeric helpers do the Float arithmetic natively where the old else arm
  sent, so the relocation is a speedup even though it is not a removal.
* Net effect on sites that can reach by-name dispatch: -27.5% since
  `f70fef67`, against -54.0% on the text count. The helper-held calls barely
  moved, so the reachable count falls more slowly than the text count.

### Where the remaining 2,325 sites sit

| Position | Then | Now | Share now |
| --- | ---: | ---: | ---: |
| Else arm of an inline fast path (class or tag test above it) | 3,442 | 1,841 | 79.2% |
| Arm of a class the guard proves exactly, still by name | 1,198 | 33 | 1.4% |
| Bare dispatch, no guard at all | 441 | 451 | 19.4% |

The known-class arm, the second largest position last time, is almost gone:
1,198 to 33 (the ADR 0296/0297 class pools and unlisted-class arms and the
follow-ups below). The 33 left are `actor` 17, `load_face_bitmap` 5, `skills` 4
and `party` 4 (23 in `Game`, 10 in `RPG2k`). Everything else is an else arm kept
as a soundness fallback (1,841) or a bare send (451); removing the else needs a
proof that it is unreachable (ADR 0290 turns such an else into a
guard-violation raise).

By owner prefix of the generated method that holds the site:

| Owner | Sites |
| --- | ---: |
| `RPG2k` | 941 |
| `Game` | 591 |
| `RGSS` | 216 |
| `LCF` | 102 |
| core and ext gems | 475 |

The core and ext gems are `Array` 94, `String` 76, `Enumerable` 71, `Hash` 58,
`Range` 49, `StringIO` 42, `IO` 27, `Integer` 19, `Enumerator` 13, `Struct` 11,
`File` 7 and a tail of smaller owners.

The guard shape directly above the site is `core_exact_class_chain` 1,064,
`no_guard_nearby` 531, `owner_class_chain` 340, `rgss_native_class_guard` 238 and
`numeric_tag_guard` 152. The nearest marker family is `POLY` 493, `NONE` 397,
`POLY_SMALL_N` 255, `NATIVE_CORE_DIRECT` 250, `NATIVE_DIRECT` 130 and
`INDEX_EXACT` 127. 1,684 sites carry no `POLY_DIAG` line.

### Top 25 method names

| # | Name | Now | Then | Cumulative share |
| ---: | --- | ---: | ---: | ---: |
| 1 | `[]` | 208 | 619 | 8.9% |
| 2 | `empty?` | 205 | 258 | 17.8% |
| 3 | `size` | 187 | 260 | 25.8% |
| 4 | `to_s` | 151 | 152 | 32.3% |
| 5 | `length` | 85 | 97 | 36.0% |
| 6 | `to_enum` | 66 | 63 | 38.8% |
| 7 | `new` | 66 | 131 | 41.6% |
| 8 | `to_i` | 60 | 60 | 44.2% |
| 9 | `[]=` | 51 | 267 | 46.4% |
| 10 | `push` | 50 | 95 | 48.6% |
| 11 | `width` | 47 | 113 | 50.6% |
| 12 | `y=` | 44 | 87 | 52.5% |
| 13 | `x=` | 44 | 83 | 54.4% |
| 14 | `update` | 42 | 87 | 56.2% |
| 15 | `name` | 37 | 54 | 57.8% |
| 16 | `include?` | 37 | 53 | 59.4% |
| 17 | `height` | 33 | - | 60.8% |
| 18 | `inspect` | 28 | - | 62.0% |
| 19 | `flash` | 25 | - | 63.1% |
| 20 | `delete` | 22 | - | 64.0% |
| 21 | `key?` | 21 | - | 64.9% |
| 22 | `first` | 21 | - | 65.8% |
| 23 | `to_f` | 20 | - | 66.7% |
| 24 | `string` | 19 | - | 67.5% |
| 25 | `pack` | 19 | - | 68.3% |

241 distinct names remain (329 before). "-" means the name was outside the old
top 25. `party` (264), `dispose` (169) and `id` (161) left the top of the table:
they were the exact-class arms that sent by name. What is left is dominated by
core container names (`[]`, `empty?`, `size`, `to_s`, `length` are 836 sites,
36%) in a tag chain whose else is the only by-name path.

### Why the sites are still dynamic (top categories)

Exclusive categories, largest first; the first matching rule wins (see
`category` in the script). "Then" is the `f70fef67` snapshot, which grouped a few
categories differently ("-" marks one it did not list).

| # | Category | Then | Now | Share now |
| ---: | --- | ---: | ---: | ---: |
| 1 | Core tag chain else, receiver not an ivar | 1,201 | 849 | 36.5% |
| 2 | Core tag chain else, receiver is an ivar | 830 | 215 | 9.2% |
| 3 | RGSS native exact-class else | 628 | 206 | 8.9% |
| 4 | `CLOSED_WORLD kept: core_or_native` | 325 | 186 | 8.0% |
| 5 | `POLY_DIAG` genuinely dynamic (all sub-reasons) | 469 | 475 | 20.4% |
| 6 | Numeric tag guard | - | 121 | 5.2% |
| 7 | No guard nearby | 162 | 95 | 4.1% |
| 8 | `CLOSED_WORLD kept: singleton_definer` | 168 | 91 | 3.9% |
| 9 | Known-class arm, still by name | 1,198 | 33 | 1.4% |
| 10 | `CLOSED_WORLD kept: dynamic_install` | 77 | 29 | 1.2% |
| 11 | Owner-chain default else | - | 21 | 0.9% |
| 12 | Everything else (`opaque_definer` 2, `unlisted_class` 2) | 23 | 4 | 0.2% |

The proof estimates the old snapshot carried (about 2,300-3,100 of its 5,081
sites removable with five proofs: class-arm lookup fixes, `{Hash, nil}` ivar
sets, copy-propagated receiver classes, RGSS argument and receiver facts, and
literal receivers) have largely been spent. The known-class lookup fixes took
1,198 to 33, the ivar sets 830 to 215, and the RGSS facts 628 to 206. What is
listed below is what those proofs did not reach.

**1. Core tag chain else, receiver not an ivar (849).** The site tests
`Array`/`Hash`/`String`/`Integer` tags inline and sends in the else: `empty?`
181, `to_s` 151, `size` 125, `length` 85, `to_i` 53, `[]` 47, `push` 26. Receiver
origin: register copy 410, unknown 122, direct-call result 113, indexed result
77, other 41. The lever is still a receiver class set carried through register
copies, return-class tables and arguments so the else becomes a guard violation;
the 849 are the receivers it has not proven. `to_s` (151) is interpolation of
arbitrary values and stays dynamic.

**2. Core tag chain else, receiver is an ivar (215).** 136 embedded ivars and 79
plain ivar reads: `size` 62, `[]` 40, `[]=` 26, `empty?` 24, `push` 22, `pop` 16.

**3. RGSS native exact-class else (206).** `new` 62, `y=` 36, `x=` 36, `flash`
18, `update` 10, `z=` 7, `fill_rect` 7. The receiver class is proven and an
argument is not provably an Integer, so the native-direct arm keeps its else.
Receiver origin: register copy 63, other 31, direct-call result 29, unknown 26.

**4. `CLOSED_WORLD kept: core_or_native` (186).** The name has a core or native
definer the world cannot exclude: `name` 37, `delete` 18, `map` 17, `string` 16,
`resume` 11, `at` 10, `write` 9. Receiver origin unknown 60, register copy 33.
Needs an exact receiver class per name (for `resume`, a Fiber).

**5. `POLY_DIAG` genuinely dynamic (475).** `receiver_class_unresolved` 210
(`inspect` 28, `call` 14, `__to_int` 12, `<=>` 12, `read` 8 among the largest
sub-group), `implicit_self_unresolved` 199 (core mrblib self calls; `to_enum` is
66 across the whole census), `traced_class_no_direct_target` 44 and
`chain/runtime_class` 22. Mostly inherent: user objects, procs and IO-like
receivers. This category did not shrink (469 to 475) while the others did, so it
is now a fifth of what is left. Unresolved receiver origins across all diag
sites: `send_result` 90, `incoming_or_unwritten_register` 49, `constant_lookup`
42, `indexed_result` 17, `captured_upvar` 11.

**6. Numeric tag guard (121).** 102 are `[]` behind an `Integer`-tag test; the
else sends by name.

**7. No guard nearby (95).** `to_f` 20, `[]` 18, `abs` 17, `===` 11, `include?`
10, `respond_to?` 7. Down from 162.

**8. `CLOSED_WORLD kept: singleton_definer` (91).** `width` 47, `height` 33: some
definer is a singleton method, so any instance might carry one.

**9. `CLOSED_WORLD kept: dynamic_install` (29).** A runtime definition site can
install a method of that name (ADR 0288 resolves only literal names).

### Block and funcall sites

`mrb_funcall_with_block` has 417 sites (448 before) and there are 462
`BLOCK_FALLBACK` markers. The `mrb_funcall*` sites in bodies are 30, mostly
literal-sized splat forwarding. The census script does not break block sites
down by name; see the ADR 0325 section below for the block-arm measurements.

## Follow-up: the exact receiver reaches every arm wrapper (ADR 0301)

Measured at master `c7ff3846` (ADR 0296 class pools and ADR 0297 unlisted-class arms merged), the same
method, before and after ADR 0301. The estimates above were written before those two landed; the table
is the measured effect of one more change on top of them.

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 3,294 | 3,138 | -156 |
| `bc2cpp_send` calls held in helpers | 24 | 24 | 0 |
| calls into `bc2cpp_slow_*` | 3,542 | 3,542 | 0 |
| calls into `bc2cpp_eqq` | 110 | 110 | 0 |
| calls into `bc2cpp_getidx` / `getidx0` / `setidx` | 2,417 | 2,397 | -20 |
| `mrb_funcall_with_block` + body `mrb_funcall*` | 476 | 476 | 0 |
| **Sites that can reach by-name dispatch** | **9,839** | **9,663** | **-176 (-1.8%)** |
| `bc2cpp_nomethod` sites (errors) | 4,435 | 4,399 | -36 |

No helper gained a caller, so all 176 are removals. By name: `size` 46, `empty?` 30, `[]` 13 (net),
`z=` 13, `last` 11, `x=` 7, `first` 6, `y=` 5, `keys` 4, `length` 4, the rest 17. Of the category table above,
"core tag chain else" is 1,368 to 1,205 (receiver not an ivar 1,091 to 971, receiver an ivar 277 to 234),
`rgss_native_exact_class_else` 567 to 517, and `core_or_native` 281 to 278; the other rows are unchanged
except `numeric_tag_guard` (82 to 111) and `no_guard_nearby` (162 to 166), which gained the sends that sit
next to a newly inlined `INDEX_EXACT` fast path.

What the remaining population looks like, from a per-site hook that printed the receiver's class set and
producer (the exact-class flow of ADR 0289/0296) at the registered-expression chains (832 sites, the
`size`/`empty?`/`first` family): 90 had a proof already (now consumed); of the other 742, the register
came from a call result 245, an ivar 160, an incoming argument 128, a `GETIDX` element 62, a constant 44,
a captured local 27, a literal joined with another value 21. For `[a, b].max` / `.min` (62 sites) the
receiver is exact and the elements are not: 1 site has all-Integer elements. For `core_or_native` (157 sites
with a flow context) 13 had an exact receiver, the others an ivar 52, an argument 41, a call result 31, an
element 14. So the estimate above for item 1 ("copy-propagated receiver classes", 300-450 sites) overstated
what was left to propagate: copies, return values and arguments were already followed, and the unknown
roots are what is left.

## Follow-up: RGSS native result facts (ADR 0302)

Items 4 (RGSS arguments and receivers) and 6 (`singleton_definer`) above were attacked with audited result
facts for the RGSS getters (`Bitmap#width`/`height`/`rect`/`text_size`, `Rect#x`/`y`/`width`/`height`,
`Color`/`Tone` components), the exact-receiver call of a zero-argument native wrapper, and an
instance-receiver proof that lets a `.singleton` definer be ignored. Same method as above, master
`c7ff3846` as the base (`bc2cpp_send` 3,224 here because the base was re-measured on that commit):

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 3,224 | 3,186 | -38 |
| `bc2cpp_slow_*` calls in bodies | 3,542 | 3,523 | -19 |
| `NUMERIC_OPERAND_PROOF` arms | 361 | 373 | +12 |
| `NATIVE_EXACT_DIRECT` calls | 80 | 114 | +34 |
| `CLOSED_WORLD kept: singleton_definer` | 167 | 130 | -37 |

The estimate of 100-168 for item 6 was too high: only receivers the exact-class flow can name (exact
`Bitmap`/`Rect`, `nil`-or-`RPG2k::Window`) qualify, and 130 sites still have an unnamed receiver. The `width`
count stays high because `Game::Map#width` and the `Window` readers are data-driven.

## Follow-up: block arms reach nested and re-counted sends (ADR 0310)

The block and funcall sites above were attacked at the engine's literal-block sends. The census does not
split `mrb_funcall_with_block` by owner, so the numbers below are the generated functions whose names start
with `Game_`/`RPG2k` (the engine, 356 literal-block sends) and everything else. Master `247a34e4` as the
base, the same tree with `BC2CPP_BLOCK_ARM_REACH=0` as the control (byte-identical to master):

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| engine literal-block sends, direct call with the block | 277 | 307 | +30 |
| engine literal-block sends, dynamic dispatch only | 68 | 38 | -30 |
| engine `&expr` block sends (`EXPLICIT_BLOCK_ARG`) | 11 | 11 | 0 |
| all owners, direct / dynamic only | 370 / 77 | 401 / 46 | +31 / -31 |
| `mrb_funcall_with_block` sites, engine | 328 | 287 | -41 |
| `mrb_funcall_with_block` sites, everything else | 120 | 120 | 0 |
| `bc2cpp_send`, `mrb_funcall*`, `bc2cpp_slow_*` callers | unchanged | unchanged | 0 |

All 41 funcall sites are removals (dead else of a proven, yield-free arm); the other 20 converted sends are
relocations: they keep a by-name else for receivers that are not exactly an Array, Hash or Range. Why the
remaining 38 engine sends stay dynamic only: `Array.new(n) { }` 10, `RGSS::Profiler.section` 9, `loop` 6,
`File.open` 4, `reduce` 4, `index` 3, `each_line`/`each_char` 2, and nested sends the proof still refuses 0
(all 25 were taken). The `&expr` ones are `reject(&:sym)` 6, `select(&:sym)` 4 and `each(&blk)` 1.

## Follow-up: where the container receivers come from (ADR 0308)

The two `core_tag_chain_else` categories counted for the rpg2k gem only (functions named `RPG2k*` or `Game*`; every gem
together is 971 and 234) at master `e1c671e4`: `receiver_other` 714 and `receiver_is_ivar` 204. A temporary hook at
`compile_insn` printed the exact-class flow's mask for each receiver register and its reaching definitions. The
producer of the receiver, 913 sites with a flow context:

| producer | sites |
| --- | ---: |
| `@ivar` read | 214 |
| call result (`SEND0` 130, `SSEND0` 63, `SENDB` 31, `SSEND` 23, `SEND` 12, `AREF` 10) | 269 |
| `GETIDX` element of another container | 124 (+28 joined with a literal) |
| incoming argument | 90 |
| reaching definitions refused | 67 |
| captured local (`GETUPVAR`) | 41 |
| constant | 34 |
| rest | 74 |

Why the 215 ivar-rooted sites have no usable class pool (first store that drops the pool, all stores at the final
fixpoint): a constructor or setter argument 47 (`Scene::Base#initialize @parent = parent` alone is 26), the result of
`compact`/`map`/`select`/`uniq`/`dup`/`Array.new` on an unknown receiver 63 (+29 reading it through `Party#actors`), a user
method result 14, an element of another container 12, several of those 24, a numeric ivar 8, an `attr_writer` or a
Symbol/String spelling of the name 26, and 19 sites whose pool is exact but whose consumer (`ARRAY_PUSH`) has no exact arm.
There is no single missing rule; the argument-shaped rows cannot be pooled because any `x.new(...)` with a non-constant
receiver may construct any class. Optimistic experiments (unsound, not shipped) measured the ceiling of two obvious
rules: core container result classes on exact receivers move the categories by 4 of 1,205 sites, `Array.new`/`Hash.new`
results by 12 with 34 relocations into `INDEX_EXACT` Array else arms.

What did move, and by how much (sites that can reach by-name dispatch for the rpg2k gem, the sum of `bc2cpp_send` and the
`getidx`/`setidx`/`slow_*`/`eqq` callers): ADR 0308's captured-local class flow, 7,625 to 7,558 (-67), of which 41 are hash
index arms with no else, 9 are Array index arms that relocated their by-name `[]` into an inline else (already netted
out), and 11 are slow-path numeric helpers. The two named categories moved by 7 (`receiver_other` 714 to 707) and 0.

Reproducing the numbers: a worktree checkout has empty `3rd/*` submodule directories, so `3rd/mruby` is empty, the native
scan sees no mruby core and the closed world refuses most proofs. `bc2cpp_send` is then about 8,000 instead of 3,030 and
every category above is wrong; check the first line of the census before trusting a run.

## Follow-up: exact RGSS native receivers (ADR 0307)

The `rgss_native_exact_class_else` category (463 of the 2,205 `RPG2k_*`/`Game_*` sites at master `359b9abd`)
grouped by why the receiver class was unproven, from a temporary hook that printed the exact-class flow's class
set, the producer of the receiver register and the ivar pool state at each site:

| Root cause | Sites |
| --- | ---: |
| `Bitmap.new(w, h)`: the constructor arm tests both Integer tags and dispatches for the String form | 120 |
| the flow already proves one class (74) or nil plus one class (90); the older guarded arms ignored it | 164 |
| call result 41, ivar pool dropped or structural 49, captured local 33, argument 21, `GETIDX` element 21, nil-written register 9 | 174 |
| `Hash#clear`, no diagnostic row | 5 |

EXACT_NATIVE_WRAPPER (ADR 0307) takes the 164. Same method, kill switch against default:

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 3,030 | 2,851 | -179 |
| of them in `RPG2k_*`/`Game_*` | 2,205 | 2,047 | -158 |
| `rgss_native_exact_class_else`, rpg2k only / all gems | 463 / 516 | 305 / 337 | -158 / -179 |
| `bc2cpp_nil_receiver` calls (cold nil arm of a new NILABLE_RECEIVER site) | 787 | 868 | +81 |
| `bc2cpp_nomethod` sites | 4,409 | 4,365 | -44 |

98 of the 179 are plain removals; 81 moved the by-name path into the nil arm of `bc2cpp_nil_receiver`, so the net on
sites that can reach by-name dispatch is -98. The remaining 305 are the 120 constructor sites (an Integer proof
for the arguments, not built), the 174 unprovable receivers and 12 sites the flow proves but a Fixnum argument
probably keeps.

## Follow-up: exact receivers reach the compiled core (ADR 0314)

Measured on the wio closed world at `43031b24`, shipped pass. A send with no block whose receiver is an exact
`Array`/`Hash` (ADR 0280) now calls the compiled core body when the body cannot suspend a Fiber.

| | Before | After |
| --- | ---: | ---: |
| cached dynamic sites | 3,240 | 3,159 |
| `bc2cpp_send` sites | 2,815 | 2,734 |
| engine `bc2cpp_send` sites | 2,377 | 2,296 |
| `CORE_EXACT_DIRECT` sites | 0 | 81 (`max` 46, `min` 31, `uniq` 3, `fetch` 1) |

All 81 are removals. What is left of the `core_or_native` kept-else category (278 engine sites) is a receiver
proof problem: 14 of its sites have an exact receiver. `BC2CPP_CORE_EXTEND=0` restores the earlier output
byte for byte. The ADR also holds the table of all 220 core-source methods and the Fiber-guard measurements.

## Ranking by executed count

The counts above weigh a start-up site like a frame-loop site. `SITE_PROFILE`
(ADR 0298) counts executions instead. It is opt-in and changes no generated code
unless `BC2CPP_SITE_PROFILE` is set.

```sh
# 1. Generate with counters; the site table lands in SITES/<OUT_SYMBOL>.sites.tsv.
#    The mrbgem.rake builds forward the environment, so a game build needs only the export
#    (delete the gem's generated *_gen.cpp so rake regenerates it).
export BC2CPP_SITE_PROFILE=/tmp/sites
# 2. Run the workload with BC2CPP_SITE_PROFILE_OUT=HITS; each process writes
#    HITS/<symbol>.<pid>.hits at exit. The optcarrot benchmark builds and runs itself:
MRBC=<host mrbc> BC2CPP_SITE_PROFILE=/tmp/sites BC2CPP_SITE_PROFILE_OUT=/tmp/hits \
  ruby tools/optcarrot_probe/compiled_run.rb 180
# 3. Rank (several --workload NAME=DIR pairs give a column each).
ruby scripts/bc2cpp_dynamic_site_census.rb --rank /tmp/sites --workload optcarrot=/tmp/hits \
  --top 30 [--tsv ranked.tsv]
```

* **Sites.** Every `bc2cpp_send(M, ...` and `mrb_funcall{,_id,_argv,_with_block}(M, ...`
  call is rewritten to `(bc2cpp_site_hit_<symbol>(ID), fn)(M, ...)`. The by-name
  dispatcher `bc2cpp_funcall_argv`, which every send ends in, is not counted, or each
  send would count twice. `mrb_yield_argv` is a block call and is not counted.
* **Keys.** A site is identified by `<symbol>` (the gem), the id, and the generated line
  and enclosing function in the *uninstrumented* output (the counters add lines only in
  a header, and a check proves peeling them gives the plain text back byte for byte).
  The reason category is the census's own (`tools/bc2cpp/site_census.rb`), so the static
  and executed tables agree on it.
* **Stale builds.** Each hit file carries a digest of its site table, and the ranker
  refuses a mismatch. The optcarrot runner removes its gem's objects first, because a kept
  mruby build directory does not rebuild the gem when only its temp-dir sources change.
* **What a hit is.** One call that reaches the site. For the else arm of a guard chain
  that is a guard miss, not an execution of the method. A site inside a shared helper
  counts every caller together; the table cannot say which caller sent the receiver.
* **Not measured.** Timings of an instrumented binary mean nothing, the counters are not
  atomic, and only the workloads actually run appear.

### First measurement: optcarrot, 180 frames

Run on the master tree plus this change, `Lan_Master.nes`, checksum 59662 (equal to
CRuby's). The optcarrot build is not the wio closed world: it is optcarrot's own
closed world (326 compiled methods, 1,083 instrumented sites), so these numbers say
where the *probe's* leftover dispatch runs, not where the game's does. 7,818,761
by-name dispatches in 180 frames; 180 of 1,083 sites ran at all; the top 4 sites
are 84.9% of the hits.

| # | Hits | Share | Site (generated function) | Why it stayed dynamic | Lever that would remove it |
| ---: | ---: | ---: | --- | --- | --- |
| 1 | 2,667,211 | 34.1% | `[]` in helper `bc2cpp_getidx` | the helper's by-name tail, reached when the receiver is not an exact Array/Hash/String with a fitting key | Probably `Integer#[]` (optcarrot's bit-read shim), not confirmed per caller. An Integer-receiver arm in the helper, or an Integer fact at the callers (NUMERIC_OPERAND_PROOF) |
| 2 | 1,773,013 | 22.7% | `@conf.loglevel`, `CPU#run` | `dynamic_no_registered_definition`: `Config#loglevel` comes from `attr_reader id` inside an `each_value` loop, so the registry sees no definer | Enumerate the names a constant-driven `attr_reader`/`define_method` loop installs (ADR 0288 handles literal names only), plus an exact `Config` class for `@conf`; then `ivar_accessor_call_code` |
| 3 | 1,339,857 | 17.1% | `@bg_pixels.rotate!` , `PPU#load_tiles` | one definer (`Array#rotate!`, core mrblib), receiver class unresolved | Class pool for `@bg_pixels` (`[0] * 16`: needs the class of an `Array#*` result, ADR 0289/0296), then a direct call to the compiled core body (ADR 0264) |
| 4-5 | 856,086 each | 10.9% each | `send(mode, ...)` / `send(instr)`, `CPU#r_op` | `send` with a computed name | A new proof: the names come from the constant `DISPATCH` table, so expand the send into a switch of direct calls. ADR 0279 only makes the proofs see such a send |
| 6-7 | 129,833; 51,185 | 1.7%; 0.7% | `@bits.even?`, `APU::Noise#sample` | one definer, `@bits` class unresolved | Integer ivar typing (numeric ivars, ADR 0279) for `@bits` |
| 8-10 | 22,471 each | 0.3% each | `send` ×3, `CPU#w_op` | computed-name `send` | as 4-5 |
| 11 | 17,465 | 0.2% | `@store[addr][addr, value]`, `CPU#store` | no guard: the receiver is an element of `@store`, an Array of `Method`/`Proc` objects | An exact `Method`/`Proc` arm for `[]`, or an element-class fact for `@store` (array element layout) |
| 12-14 | 6,392 each | 0.1% each | `send` ×3, `CPU#rw_op` | computed-name `send` | as 4-5 |
| 15 | 6,230 | 0.1% | `~` , `CPU#_sbc` | one definer, receiver class unresolved | Integer proof for the operand |
| 16 | 5,272 | 0.1% | `run`, `PPU#sync` | `chain/runtime_class` | Inherent: the receiver class is chosen at run time |
| 17-18 | 3,087; 3,072 | <0.1% | `*`, `round` in `bc2cpp_slow_mul_f` / `bc2cpp_slow_round` | the numeric slow-path helpers' by-name tail | None worth taking: Float and non-numeric operands |
| 19-22 | 3,072 each | <0.1% | `polar`, `conjugate`, `real`, `sort` in `Palette.nestopia_palette` blocks | no bytecode definer (Complex/native), start-up palette build | Cold: runs once per palette entry |
| 23 | 2,477 | <0.1% | `each` with a block, `PPU#poke_2007` | `BLOCK_FALLBACK` | `BLOCK_CORE_DIRECT` / yield-free block proof (ADR 0283) |
| 24-30 | 1,498 down to 672 | <0.1% | `bc2cpp_getidx0` `[]`, `uniq!`, `polar`, `map`, `bc2cpp_slow_add_f` `+`, `include?`, `polar` | helpers and start-up palette code | Cold, or as 1 and 17 |

The lever column is an analysis of the generated C++ and the optcarrot source, not a
measurement: nothing was built to confirm that a proof removes a site. Rows 1 and 3-15
are the sites worth a proof; the sites after row 15 together run 35,206 times, 0.45% of the hits.
`--rank` prints the same ranking, with a category-level lever per row, from any hit set.

### After ADR 0304 (loop-installed accessors)

Same workload and tree plus `LoopInstallers`: 6,025,773 by-name dispatches (-1,792,988, -22.9%), 158 of 1,085 sites
ran. Row 2 (`@conf.loglevel`) is gone from the table (1,773,013 to 0; the rest of the category, mostly `Config`
readers used at start-up, 1,784,121 to 188). `@conf.loglevel` is now a runtime-class chain with a direct ivar read
(`POLY_SMALL_N`), not an exact-class arm: `@conf` is assigned from a constructor argument, which the class pools do
not follow (ADR 0295). The ranking is now `[]` in `bc2cpp_getidx` 44.3%, `rotate!` 22.2%, the `send` sites 29.9%.

Row 1 resolved (ADR 0305): a receiver histogram at the tail showed 2,552,721 Integer (the probe's
`Integer#[]` shim; mruby core has none), 105,005 `IdentityHashShim` and 9,485 `Method`. Feeding the shim to
bc2cpp gives the helper an exact-class Integer arm; re-measured total 5,266,040 hits (-32.6%), helper tail
114,490, same 1,083 sites, checksum 59662.

The ranker also groups the hits by reason category (a start-up palette site and a
frame-loop site share one): `shared_helper` 34.2%, `poly_diag` single definer with
implicit self (all `send`) 23.0%, `poly_diag` no definer with unresolved receiver
(`loglevel`, palette) 22.8%, `poly_diag` single definer with unresolved receiver
(`rotate!`, `even?`) 19.5%, everything else 0.5%. By contrast, the core-tag-chain and
owner-chain categories, the largest in the static tables above (511 instrumented sites
here), ran 676 times in total: this workload does not exercise the shapes that make up most
of the static count.

### Not run

* **The game smoke.** It needs the SDL engine and an RPG2000/2003 project
  (`data/Nepheshel206beta`, `data/mtf-meido-action`, fetched by `scripts/download-*.bash`)
  and runs in CI (`rpg2k_boot_check.bash`). Neither the SDL build nor the games were
  available where this was written, so there is no game ranking, and the wio closed-world
  sites above have no executed counts. The hook is the same `BC2CPP_SITE_PROFILE` export
  before the build, then `BC2CPP_SITE_PROFILE_OUT` while the smoke runs; the three compiled
  gems write one hit file each.
* **Per-caller counts for helper sites**, and any other workload (the MV and wio smokes).

## Element reads of mutable containers (ADR 0312)

`BC2CPP_ELEMENT_REPORT=<tsv>` (`tools/bc2cpp/element_site_report.rb`) writes one row per instruction that can
still reach a by-name call, with the origin of its receiver, and one row per write into a container ivar with the
class set of the value; `scripts/bc2cpp_element_site_report.rb <tsv>` aggregates it:

```sh
BC2CPP_ELEMENT_REPORT=/tmp/elements.tsv MRBC=<host mrbc> ruby scripts/bc2cpp_coverage_report.rb > /dev/null
ruby scripts/bc2cpp_element_site_report.rb /tmp/elements.tsv
```

On the wio closed world (engine owners): 15,349 sites can reach by-name dispatch, 1,151 read an element, 380 of those
an element of an ivar container, and only 28 of those 380 sit on an ivar whose every creation and write has a known
class set (ceiling, before any alias check). The element class of a mutable container is therefore limited by the
class of the values stored, which are mostly method results and parameters, not by aliasing; ADR 0312 records why
nothing was built. The report changes no generated code.

## Kept else arms and interface tables (ADR 0315)

`BC2CPP_ITAB_REPORT=<tsv>` (`tools/bc2cpp/interface_table_report.rb`) writes one row per explicit-receiver send that has
a guard chain (family, the else arm of the final code, every `ClosedWorld#refusal` gate the name fails, the proven
receiver classes or the flow mask that fell short, the receiver's origin, the chain's classes, what each cell of a proven
set would be, the name's native registrations) and `<tsv>.names` (one row per method name);
`scripts/bc2cpp_interface_table_report.rb <tsv> [owner-regexp]` aggregates them:

```sh
BC2CPP_ITAB_REPORT=/tmp/itab.tsv MRBC=<host mrbc> ruby scripts/bc2cpp_coverage_report.rb > /dev/null
ruby scripts/bc2cpp_interface_table_report.rb /tmp/itab.tsv '\A(RPG2k|Game)'
```

On the wio closed world (master `43031b24`): 5,730 sends have a chain, 4,377 end in `bc2cpp_nomethod`, 783 have no
dispatch left, and **570 still dispatch by name**. 507 of those (89%) have a receiver class set the exact-class flow
does not prove, so no per-class table can exist; of the 63 with a proven set, at most 42 (`@window.update`,
`@interpreter.update`, one `start`) could lose the dispatch, and only with three new proofs together (a definer inside
`class << <class>` is a class-object definer, per-class native/outside-Ruby resolution, a cell check against the
set rather than the name's whole definer set). ADR 0315 records why nothing was built, the annotation inventory
(and why an RBS-style form does not fit), and the per-name method-set sizes (94% of the polymorphic names have four or
fewer Ruby implementers). ADR 0328 later builds the tables anyway, opt-in and for source size and lookup shape rather
than else-arm removal. ADR 0296's "372 kept by name" rows are sites with no dispatch left in the final code. The
report changes no generated code (`shipped.cxx` is byte-identical with it on).

## Follow-up: which producer leaves a receiver unproven (ADR 0309)

The `register_copy` and `direct_call_result` origins above are a text heuristic. To see the producing
method, build with a tag on every by-name line and join the shipped sites to it:

```sh
MRBC=<host mrbc> BC2CPP_SEND_ROOT_REPORT=/tmp/keep/rows.tsv BC2CPP_COVERAGE_KEEP_DIR=/tmp/keep \
  ruby scripts/bc2cpp_coverage_report.rb > /dev/null
ruby scripts/bc2cpp_send_root_report.rb /tmp/keep [FUNCTION_PREFIX_REGEX]
```

The report is for ranking (the tag changes the generated text). Measured on `master` `2b317417`, the
2,196 shipped rpg2k sites have these receiver producers: a call result 504, an ivar 503, an incoming
argument 303, a `GETIDX` element 203, a constant 166, an Array literal 107, a captured local 81, 202 not
attributed. Of the 503 ivar receivers 225 have no class pool, and the first blocker of 99 of those is a
constructor argument (`initialize` is excluded from argument pools, ADR 0295); 205 have one and still go
by name for the consumer's own reasons. The call results are mostly project getters over an unpooled slot
(about 150), names a foreign Ruby or native source spells (about 110) and `Bitmap.new`/`Sprite.new`
(69). ADR 0309 takes the readers (`attr_reader` returns its slot's class set) and the exact-Array arms
(`ARRAY_PUSH`, the TYPED call of a core body): 63 fewer rpg2k sites and 256 fewer that can reach by-name
dispatch (7,605 to 7,349), all removals. No remaining cause is above about 5% of the sites.

## Caveats

* The static tables above count source sites, not executions. A site in a cold scene
  weighs the same as one in the frame loop; the section "Ranking by executed count" is
  the measurement that applies a profile.
* The marker is the nearest preceding family comment within 25 lines and can be
  a neighbour's; the exclusive categories use position and guard shape first so
  they do not depend on it.
* The receiver origin is a text heuristic over the register's last assignment. A
  register copy hides the real origin, so `register_copy` is a floor on what is
  unknown, not an answer.
* The `unlisted_class_call` reasons came from a one-run instrumentation that is
  not in the tree; they are per class and name, and the counts here map each
  site to its class's dominant reason.
* Removal estimates are judgements. None was built or measured.
* The baseline is a saved `shipped.cxx` from before the round, not a rebuild
  of the old commit; its 9,733 `bc2cpp_send` lines match the figure quoted for
  it.

## Element classes of frozen tables (ADR 0306)

`BC2CPP_FROZEN_TABLES=0` is the "before". On the merged tree it moved 6 numeric operator sites
(see the ADR for the per-helper counts) and nothing else: element classes of mutable
Arrays/Hashes in ivars and locals, the bulk of the unknown receiver roots, are not covered.

## Numeric operand roots and tuple returns (ADR 0311)

The `bc2cpp_slow_*` rows of the tables above are guarded numeric operators whose operands NumericFlow could not prove.
`BC2CPP_NUMERIC_ROOTS=<file> MRBC=... ruby scripts/bc2cpp_coverage_report.rb` writes one `ROOT` line per such operator
of the shipped pass (owner, operator, class set per operand, the leaves it is computed from), through
`tools/bc2cpp/codegen_numeric_roots.rb`; the generated code is byte-identical with it on. On the branch point
`247a34e4` the engine owners (`RPG2k*`, `Game*`) had 2,384 sites with an unproven `+ - * / < <= > >=` operand. No root
family is worth more than 13% even when forced to Integer (`GETIDX` results -321, `size`/`length`/`count` -140,
`hp`/`width`/`x`-style getters -109, `AREF` -91, captured locals -38, native-spelled ivars -30). The sound slice built
is `AREF` of a fixed-arity Array return: master `2b317417` 3,040 engine helper calls to 2,999 (-41, removals), all in
four methods because the other tuples' inputs are parameters, native-spelled ivars or Array elements.

## Follow-up: constructor argument pools (ADR 0313)

Measured at master `43031b24`, kill switch against default, same tree, `3rd/*` populated:

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 2,815 | 2,814 | -1 |
| of them in `RPG2k_*`/`Game_*` | 2,009 | 2,007 | -2 |
| generated callers of `bc2cpp_getidx` | 2,095 | 2,070 | -25 |
| `bc2cpp_slow_*` lines, `bc2cpp_eqq` calls, `bc2cpp_nil_receiver` calls | 3,498 / 110 / 877 | same | 0 |
| `bc2cpp_nomethod` sites | 4,360 | 4,368 | +8 |

Removal, not relocation. The 675 `new` sends of the build are all visible (69 with no arguments, 301 on a class with a
Ruby initialize, 298 on a native or core class, 7 rooted in a singleton or `self.class`, none unresolved); the "58
computed `new` sites" were constants inside `rescue`-covered methods that `agreed_constant_name` refuses. The
`Bitmap.new(w, h)` Integer-tag sites do not come from constructor arguments: their `w`/`h` are failed numeric constants
(`LINE_H`, `SCREEN_W`, `TILE`, `FACE_SIZE`), `Rect`/`Bitmap` native results, `Array#max` and `Window#width`.

## Follow-up: where a value goes (ADR 0316)

The census above counts by-name sends; this one counts creation sites (`LAMBDA`, `BLOCK`, `ARRAY`, `HASH`, `STRING`,
`new`) and asks whether the value leaves the frame that made it, with the shared escape analysis
(`BC2CPP_ESCAPE_REPORT=<tsv>`, `scripts/bc2cpp_escape_report.rb tsv shipped.cxx`). Wio closed world, master
`56b14771`, shipped pass:

| Measure | Value |
| --- | ---: |
| creation sites in methods that ship | 4,114 |
| `LAMBDA` sites / confined today / confined by the analysis / newly confined | 3 / 1 / 1 / 0 |
| BLOCK_FALLBACK regions / proven confined (callee set closed over receiver classes) | 466 / 109 |
| `each` sends the analysis cannot prove (5 of the 11 `each` definitions keep their block) | 168 of 206 |
| Arrays / Hashes / objects used only locally (stack candidates, count only) | 46 / 44 / 3 |
| constructors whose `self` does not leave | 51 of 82 |
| methods that newly compile with BLOCK_FALLBACK_PROVEN | 1 (`Array#combination`) |
| `shipped.cxx` with `BC2CPP_ESCAPE_ANALYSIS=0` against master | byte-identical |

## Follow-up: provable errors and post-call facts (ADR 0317)

`BC2CPP_PROVABLE_ERROR_REPORT=<tsv>` and `BC2CPP_REFINE_REPORT=<tsv>` (run with `BC2CPP_CALL_FACTS=0` to measure the
potential), aggregated by `scripts/bc2cpp_refine_report.rb tsv [--list-bugs]`. Wio closed world, master `147fe7e6`:

| Measure | Value |
| --- | ---: |
| provable errors in the three engine gems (nomethod, nil receiver, arity, operator, zero divide, undefined name) | 0 |
| explicit by-name sites / lines in the engine gems | 2,154 / 2,225 |
| kept-else sites / receiver unproven | 438 / 378 |
| by-name sites bounded to user classes by the forward interface / dead else | 105 / 100 (64 kept else) |
| realized `bc2cpp_send` / kept else arms / `bc2cpp_nomethod` | 2,666 -> 2,603 / 462 -> 399 / 4,318 -> 4,380 |
| backward interface (unsound) upper bound, kept-else removals | 114 |
| NOMETHOD_REVIEWED keys: monomorphic / polymorphic / narrowed / native arms / untraced / candidate bug | 1,774 / 567 / 289 / 58 / 252 / 1 |
| POLY_SMALL_N chains with two classes on one definition | 50 of 1,525 (177 of 8,906 compares) |
| `shipped.cxx` with `BC2CPP_CALL_FACTS=0` against master | byte-identical |

## Follow-up: per-class resolution for proven receiver sets (ADR 0323)

`BC2CPP_NATIVE_ARMS_REPORT=<tsv>` (`tools/bc2cpp/native_arms_report.rb`, aggregated by
`scripts/bc2cpp_native_arms_report.rb tsv [owner-regexp]`) writes one row per by-name site with its receiver set `S` (proven by
the exact-class flow or bounded by call facts, whatever the members), each member's cell kind and the gates that fail
today. Wio closed world, master `7818f0f5`, engine gems:

| Measure | Value |
| --- | ---: |
| by-name sites / whose else still dispatches (kept marker 372, bare send 1,553) | 2,009 / 1,925 |
| dispatching sites with a bounded set (proven 163, call facts 107) / unproven | 270 / 1,655 |
| bounded sites: kept else / bare send | 92 / 178 |
| bounded sites a cell blocks (native with no entry, guarded `:int` entry, Ruby body not direct-callable) | 186 |
| `bc2cpp_send` / `bc2cpp_nomethod`, switch off -> on | 2,513 -> 2,463 / 4,380 -> 4,441 |
| by-name sites removed (`update` 42, `Hash#delete` 8) / new by-name sites | 50 / 0 |
| `shipped.cxx` with `BC2CPP_NATIVE_CLASS_ARMS=0` against master | byte-identical |

Sites with an unproven receiver set cannot be fixed by these proofs. The three proofs of ADR 0315 (class-object
definers, per-class native/outside resolution, a cell check against `S`) remove nothing alone; together they remove the
42 `update` sites of the `class << Graphics` probe, and FLOW_CORE_DIRECT the 8
`Hash#delete` sites of a flow-proven Hash.

## Follow-up: numeric constants and native `:int` arguments (ADR 0318)

`BC2CPP_NATIVE_INT_ARGS=<tsv>` writes one `NINT` line per `:int` argument of a native entry point (`Bitmap.new`, exact
`Sprite#x=`-style calls) the Fixnum proof does not cover: the site, the writer of the register and the leaves behind it;
`BC2CPP_NUMERIC_CONSTANTS_REPORT=<tsv>` writes each constant name with a definition and no interval, and why.
Wio closed world, master `b1ab8310`, `3rd/*` populated, kill switch `BC2CPP_NUMERIC_CONSTANTS=0` against default:

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites | 2,607 | 2,538 | -69 |
| of them in `RPG2k_*`/`Game_*` | 1,779 | 1,714 | -65 |
| `Bitmap.new` sites without a tag test and else (of 115) | 0 | 65 | +65 |
| `bc2cpp_getidx`, `bc2cpp_slow_*`, `bc2cpp_eqq`, `bc2cpp_nil_receiver`, `bc2cpp_nomethod` | 2,033 / 3,355 / 111 / 892 / 4,386 | same | 0 |
| constants with a proven Fixnum interval | 693 Fixnum constants | 725 | |

Removal, not relocation. The 115 `Bitmap.new` sites never asked the Fixnum proof (29 are removed by asking it); 36
more by an interval for `+ - * /` of constants. Of the 50 left, 17 are the String file-load form, 11 `Array#size`/`max`
results, 8 user readers, 4 `Bitmap#width`/`height`, 4 parameters. `flowfail` of a constant means `NumericFlow` does not
model a class body, not that the constant is not an Integer; `LINE_H`, `SCREEN_W`, `TILE` and `FACE_SIZE` were Fixnum
constants all along. `shipped.cxx` with the switch off is byte-identical to a clean master build.

## Follow-up: interval operands for the Fixnum proof's consumers (ADR 0326)

`BC2CPP_NUMERIC_INTERVALS=0` is byte-identical to master. Wio closed world, master `7818f0f5`, `3rd/*` populated, default
against master:

| Measure | master | default | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites | 2,538 | 2,496 | -42 (Array `[]`/`[]=` else) |
| `bc2cpp_slow_*` callers (`add_f` 720, `sub_f` 479, `mul_f` 451 -> 719 / 473 / 441) | 3,343 | 3,326 | -17 |
| `mrb_fixnum_p(` / `mrb_integer_p(` tests | 3,597 / 3,822 | 3,444 / 3,510 | -153 / -312 |
| arms proven (`operands proven Fixnum`) / proven Array index sites | 388 / 0 | 556 / 42 | +168 / +42 |
| `bc2cpp_getidx`, `bc2cpp_setidx`, `bc2cpp_nomethod` | 2,066 / 210 / 4,386 | same | 0 |

## Follow-up: INTEGER_CONSTANT_PROOF soundness (ADR 0324)

Two latent holes in the older proof are closed: a native `mrb_define_const`/`mrb_const_set` of a bare name now
withdraws it (the old scan matched no name), and a `SETCONST` that a jump lands on (`X = c || 1`) is no longer an
Integer definition. Wio closed world, master `7818f0f5`, `3rd/*` populated, master against the fix:

| Measure | master | fix |
| --- | ---: | ---: |
| `bc2cpp_send` / `bc2cpp_slow_*` / `bc2cpp_getidx` / `mrb_fixnum_p(` / `bc2cpp_nomethod` | 2,538 / 3,343 / 2,066 / 3,597 / 4,386 | same |
| Integer constants / with an exact value | 693 / 470 | 691 / 468 (`MAX`, `MIN`) |
| `shipped.cxx` digit-masked diff | | 28 lines: three symbols, two inlined reads of `Game::Variables::MAX`/`MIN` |

`MAX`/`MIN` collide with the native `Float::MAX`/`MIN` (`mruby-numeric-ext`); the two engine reads
(`game.rb:1521-1522`) resolve to the Integers, so behaviour did not differ.

## Follow-up: EXT prefixes folded into their instruction (ADR 0320)

Wio closed world, master `cd86085f`, same tree with `BC2CPP_EXT_PREFIX=0` (byte-identical to master) against the default.
Three ireps carry a prefix (class bodies of `LCF::Schema`, `RPG2k::Interpreter`, `RPG2k::Scene::Map`: 635 `EXT2`, 9 `EXT1`).

| Measure | off | on |
| --- | ---: | ---: |
| constant pools / argument pools | 658 / 110 | 796 / 115 |
| `bc2cpp_send` in generated bodies / with guarded fallbacks | 2,603 / 3,028 | 2,582 / 3,006 |
| `INDEX_EXACT` arms / `NUMERIC_OPERAND_PROOF` arms removed | 977 / 423 | 1,000 / 427 |
| `bc2cpp_nomethod` sites / ivar pools / frozen table shapes | 4,380 / 187 / 49 | 4,380 / 187 / 49 |

## Baseline after ADRs 0307-0317 (master cd86085f, 2026-10-02)

One tree, one set of numbers: the eleven PRs of ADRs 0307-0317 each measured their delta on a different master, so
their deltas overlap. Full tables (totals per scope, marginal contribution of every kill switch, receiver origins,
why-kept ranking, next levers, CI shard timing, tool problems) are in `docs/bc2cpp-baseline-2026-10-02.md`. Wio closed
world, `3rd/*` populated, default switches:

| Measure | all gems | rpg2k + Game |
| --- | ---: | ---: |
| `bc2cpp_send` / `mrb_funcall*` / `mrb_funcall_with_block` | 2,603 / 28 / 401 | 1,800 / 0 / 277 |
| `bc2cpp_nomethod` / `bc2cpp_nil_receiver` | 4,380 / 890 | 4,274 / 837 |
| `slow_*` / `getidx` / `setidx` callers | 3,314 / 2,069 / 209 | 2,852 / 1,955 / 184 |
| kept-else sites (engine gems, refine report) | 375 | |
| by-name sites with a guard chain still dispatching (rpg2k) | | 453 (419 kept else, 34 send) |

By-name `bc2cpp_send` sites each landed feature removes on this tree (switch off minus master, all gems):
`EXACT_NATIVE_WRAPPERS` 209, `CORE_EXTEND` 81, `CALL_FACTS` 63, `CAPTURED_LOCAL_CLASS` 62, `EXACT_CORE_ARMS` 56,
`RETURN_ACCESSORS` 13, `CONSTRUCTOR_POOLS` 1; `BLOCK_ARM_REACH` removes 48 `mrb_funcall_with_block` sites (and
`BLOCK_CORE_DIRECT=0` gives the identical counts, so the 48 depend on it); `ESCAPE_ANALYSIS` and `TUPLE_RETURNS` do not
change the by-name count (`TUPLE_RETURNS` removes 41 `slow_*` callers). The `core-tables` CI shard is 29.7 minutes on
this master, not 24.5.

## Block sends: what keeps the dynamic line (ADR 0325, master 7818f0f5, nothing built)

`BC2CPP_BLOCK_SEND_REPORT=<tsv>` writes one row per block send and `scripts/bc2cpp_block_send_report.rb <tsv> [--gem GEM]`
aggregates it (`mruby-rpg2k` is 352 block sends, 282 with a by-name line; the scope is by gem, the baseline's 277 is by
function-name prefix). Wio closed world, `3rd/*` populated.

| Shape (rpg2k) | Sites |
| --- | ---: |
| `exact_arms`: class tests, dynamic else, receiver not proven | 227 |
| `removed`: proven class, the compiled call alone | 42 |
| `dynamic`: no compiled core callee (`new` 10, `section` 9, `loop` 6, `open` 4, `reduce` 4, `index` 3, 2 String iterators) | 38 |
| `mono_direct`: one resolved call (2 keep a chain else) | 30 |
| `explicit`: `&expr` | 12 |
| `proven_guarded`: proven class, block without a direct entry | 3 |

Every literal block is yield-free and every arm body relaxable, so 215 of the 227 `exact_arms` sites become the compiled
call alone once the receiver class is proven. Receiver of the 282 by-name sites: exact flow 4, post-call facts a usable
user-class set 0 (21 core/native-bounded, 5 unbounded), no earlier call 252. Producer: call result 76, `x || []` merge 49,
`GETIDX` element 47, incoming argument 37, constant 20, ivar 16.

Lever ceilings in the engine gems (rpg2k / lcf / rgss): SENDB facts 0; `Array.new(n) { }` 10 / 1 / 0 (all `Array.new`);
direct entry for `break`/`return` blocks 3 / 0 / 5; `Hash#delete` 6 / 2 / 0 (a flow-proven receiver that
CORE_EXACT_DIRECT does not read) and `Array#delete` 2 / 0 / 0 (no compiled body); sum 29, below the cutoff of 30, so
nothing was built.

## Proven-error arms: are they reachable? (ADR 0330, master 49f39416, nothing built)

`BC2CPP_DEAD_ARM_REPORT=<tsv>` writes one row per `bc2cpp_nomethod` / `bc2cpp_nil_receiver` arm (plus `partial_miss`,
`const_unresolved`, `arity_*` rows) and `scripts/bc2cpp_dead_arm_report.rb <tsv> [--lcov lcov.info] [--list]` aggregates it.
The shipped C++ is byte-identical with the report on. Arms of the engine gems and core, by exclusive class:

| Class | Arms |
| --- | ---: |
| (a) the else of a send with live arms | 2,739 |
| (b) the only arm of its send | **0** |
| (c) nil path, live, unguarded | 822 |
| (d) the method body is not callable by name | 86 |
| (e) guarded: probed 1,166, rescue 417, hint 76, selfset 29 | 1,688 |

The 822 (c) arms are 647 ivar reads (81 scene-lifecycle clusters: set in `start`/`build_*`, reset in `dispose`/`close_*`;
`Battle#@ui` alone is 379), 152 database chunk or element reads, 19 parameters and 4 others. Read by hand, none is a latent
bug; 88 `partial_miss` rows are one pooling imprecision (`Menu#@message` Hash against `Map#@message`). Provable errors
(sole arms, no class answers, `arity_all`, operators, nil exactly) are 0, so making them compile errors removes nothing;
the 14 `const_unresolved` rows are desktop-only constants behind `rescue NameError`.

## Follow-up: Hash#delete flow-core coverage (ADR 0327)

The eight `Hash#delete` sends above (six RPG2k, two LCF) are removed by
FLOW_CORE_DIRECT (ADR 0323). ADR 0327 adds no generator change; it adds pooled
Hash `delete`/`fetch` fixtures and a mutant on the early return to the
core-exact check. See [ADR 0327](adr/0327-bc2cpp-flow-core-hash-delete-checks.md).
## Receiver class proofs: what keeps the unproven receivers (ADR 0331, master eed615c7, nothing built)

`BC2CPP_RECEIVER_PROOF_REPORT=<tsv>` writes one row per engine explicit-receiver send that still holds a by-name line, with
the source of its receiver and what happens to the line when the receiver is forced to a class set (a forked recompile of
the one send, so the output is byte-identical); `scripts/bc2cpp_receiver_proof_report.rb <tsv>` aggregates it. 1,970 sends,
187 with a proven set, **1,783 unproven**.

| Source (unproven) | Sites | Own set removes | Floor removes (every answering class, nil allowed) |
| --- | ---: | ---: | ---: |
| call result | 491 | 110 | 71 |
| ivar | 322 | 8 | 66 |
| argument | 321 | 0 | 53 |
| `GETIDX` element | 234 | - | 6 |
| constant | 164 | - | 0 |
| other | 119 | - | 3 |
| `x \|\| []` merge | 85 | 75 | 1 |
| captured local | 47 | - | 4 |

Roots: 235 ivar sites read a pool dropped by an unmodelled store (a parameter, or a `map`/`select`/`dup` result), 54 an ivar
a native spells (`@contents` 44), 173 parameters are not pool candidates, 147 have a dropped pool, 207 call results go
through an ivar accessor, 136 through a native result, and per-class resolution of the callee completes 0 sites. A prototype
(`h.keys` and `Graphics.snap_to_bitmap` as audited native result classes, and a `<native>` placeholder of a name no linked
source defines dropped from the return join) removed 22 by-name sends against the cutoff of 30, so nothing was built; the
lever left is a call-graph audit of the RGSS natives' `self` discipline for `@contents` (about 70 floor-freed sites).

## Follow-up: native RGSS ivar families (ADR 0332)

The native Window call graph accesses `@contents` and `@cursor_rect` only on its Window receiver's `self`.
Pinned native sources and a scan for outside helper callers let the compiler keep those names poisoned for the
RGSS::Window family while pooling unrelated scene slots. The `@viewport` writer audit similarly scopes poisoning
to RGSS::Sprite/Plane/Tilemap/Window, freeing RPG2k::Window's own Ruby-managed viewport. Unknown native setter values
remain unknown.

On master `4bdd9492`, switch off against on on one tree, the Wio shipped census goes from 2,924 to 2,881 cached
by-name sites. All 43 removals belong to engine methods; 39 nil-receiver helper calls and one no-method helper call
are added, while four obsolete no-method helpers in RPG2k::Window disappear (net -3). Class ivar pools grow from 185 to 187 and argument pools from 115 to 117. With
`BC2CPP_NATIVE_IVAR_SCOPES=0`, the shipped C++ is byte-identical to master. Source changes, new outside callers or
other outside spellings withdraw the scope proof. See [ADR 0332](adr/0332-bc2cpp-native-window-ivar-families.md).

## Follow-up: native class results and absent placeholders (ADR 0333)

Audited native `keys`, `values`, `bytes`, `split`, `members`, `to_a` and `parameters` contribute Array results to
Ruby/native return joins. `Graphics.snap_to_bitmap` contributes Bitmap **or nil**. A placeholder with no linked
native definition no longer spoils a fully visible return join. The dispatch registry and original calls remain.

On master `43d4d462`, the Wio census falls from 2,881 to 2,865 cached sites: native facts alone remove nine,
absent placeholders alone seven. Class pools become 188 ivar and 120 argument pools; INDEX_EXACT arms grow
from 1,000 to 1,025. Nil-receiver helpers remain at 918, while four obsolete reviewed `dispose` fallbacks disappear.
Both new switches off reproduce master byte for byte. Together with ADR 0332, the measured gain is 59 cached sites.

Shared-name argument pools and Window width/height ivar scopes each measured zero further removals. Native setter
caller completeness and dynamic setter names still block the `contents`/`bitmap` slice. A partial `to_s` audit remains
blocked by linked definitions and aliases and is not shipped. The floor counts above overlap and are not guaranteed
achievable gains. See [ADR 0333](adr/0333-bc2cpp-native-class-results.md) for the contracts and rejected candidates.

## Follow-up: native String results (ADR 0334)

The linked native `to_s` audit now includes Fiber and the core Struct alias to its unique native inspect entry.
String subclass freedom and all compiled Ruby returns remain part of the proof; native Onig contributes nil as
well as String. Outside Ruby definitions, unknown aliases/installers and native replacements withdraw it.

On master `98914faf`, the Wio census falls another 20 sites, from 2,865 to 2,845. Class pools grow from 188/120
ivar/argument pools to 189/136; nil-receiver helpers grow from 918 to 921. Reviewed error fallbacks remain unchanged.
`BC2CPP_NATIVE_STRING_RESULTS=0` reproduces master byte for byte. The three follow-ups now remove 79 cached sites
from the original 2,924. Native setter inputs and collection element classes still need independent proofs.
See [ADR 0334](adr/0334-bc2cpp-native-string-results.md).

## Follow-up: native copy and collection results (ADR 0335)

Pinned native `dup` preserves known receiver class bits. Exact Array `compact` and
`join` results require pinned allocation helpers and override-safe core lookup.
The Wio census drops from 2,845 to 2,844 cached sends; all four receiver-proof
follow-ups remove 80 sites from 2,924. Element classes remain unknown. The collection
kill switch reproduces ADR 0334 shipped C++ byte for byte.
See [ADR 0335](adr/0335-bc2cpp-native-collection-results.md).

## Follow-up: name-wide native collection transformations (ADR 0336)

Native compact, flatten and __uniq can contribute Array results, and audited
Array/File join implementations contribute String results when File.join cannot
preserve a String subclass. The linked-source audit can admit these facts through
the broader foreign-name filter; compiled Ruby returns still join them, and aliases
and uncompiled linked Ruby definitions remain refused.

The targeted unknown-input fixtures gain proofs, but the full shipped Wio C++ is
byte-identical with the new switch on or off: 2,844 cached sends and the same pools
and helper counts. The reduction from ADRs 0332–0335 remains 80 sites. This extends
supported contracts without claiming additional census or speed savings.
See [ADR 0336](adr/0336-bc2cpp-native-array-transforms.md).

## Follow-up: native setter inputs (ADR 0337)

The setter report finds 62 named contents= candidates with Bitmap input facts
(six unresolved receivers), and 31 bitmap= candidates: 23 Bitmap, one Bitmap-or-nil,
and seven unknown inputs. The seven inputs are Graphics.transition, Ruby Window's
contents= forwarding parameter and five battle sprite producers. Computed names
remain present; these named candidates do not prove native caller completeness.

An audited bitmap writer scope isolates Sprite/Plane stores from unrelated Ruby
fields. The current shipped Wio output remains byte-identical to the parent,
with 2,844 cached sends and the same pools/helper counts. The report itself also
changes no C++. See [native setter inputs](bc2cpp-native-setter-inputs.md) and
[ADR 0337](adr/0337-bc2cpp-native-setter-input-audit.md).

### Core Ruby collection returns (ADR 0338)

Actual core bytecode can now prove collection results for known receiver and
block contexts. Literal caller blocks with no descendant break retain results of
map/select/reject/partition; zero-argument bodies such as Hash#to_h and tally are
also analyzed. The same-tree switch comparison on a84d3b60 reduces cached sends
2,858 to 2,853 (all by-name lines 2,919 to 2,914), adds one ivar pool and six exact
index arms, and preserves nil error paths through six more nil-helper sites.
Master's newly emitted block bodies explain the different starting count from
ADR 0337. Overrides, forwarded blocks, captured writes and nonlocal callee exits
retain refusal. See [core Ruby returns](bc2cpp-core-ruby-returns.md).

### Nested core results and Range inputs (ADR 0343)

On the same 959773b8 tree with the workspace's native submodule contents,
`BC2CPP_CORE_RUBY_NESTED_RESULTS=0` provides the
control for the nested helper/super analysis and audited native range contract.

| Measure | Control | Enabled |
| --- | ---: | ---: |
| Cached calls, including helper-held sends | 2,776 | 2,774 |
| Ordinary send lines in bodies | 2,349 | 2,350 |
| Block funcall lines in bodies | 403 | 400 |
| Index helper callers | 2,248 | 2,246 |
| Numeric helper callers | 3,264 | 3,264 |
| Equality helper callers | 110 | 110 |
| Other body funcalls | 30 | 30 |
| **Sites that can reach by-name dispatch** | **8,404** | **8,400** |

The four removals are three sort_by block fallbacks in
Game::Transition#compute_block_order and one size fallback in
Game::Transition#block_count_through. Two index helper callers become inline
by-name fallbacks, so their disappearance is a relocation. All changes occur
in RPG2k; core and other compiled gems retain their dynamic sites.
See [ADR 0343](adr/0343-bc2cpp-nested-core-ruby-results.md).

### Profiler block results (ADR 0344)

On e50a09dc plus the Profiler helper-frame repairs, with the same workspace
native sources, `BC2CPP_PROFILER_RESULTS=0` supplies the control.

| Measure | Control | Enabled |
| --- | ---: | ---: |
| Cached calls, including helper-held sends | 2,774 | 2,772 |
| Ordinary send lines in bodies | 2,350 | 2,348 |
| Block funcall lines in bodies | 400 | 400 |
| Index helper callers | 2,246 | 2,246 |
| Numeric helper callers | 3,264 | 3,264 |
| Equality helper callers | 110 | 110 |
| Other body funcalls | 30 | 30 |
| **Sites that can reach by-name dispatch** | **8,400** | **8,398** |

The two removed fallbacks are map width and height in RPG2k#start_new_game.
The receiver is the Game::Map returned by the map-loading block; the remaining
error branches are reviewed dead fallbacks. Game::State from the party block
also establishes two argument pools and simplifies existing guard chains.
No calls move into shared helpers. The nineteen `@map` receiver sites still
require proofs for their other writers; the earlier seventeen-site
counterfactual is not a measured saving from this change.

See [Profiler block results](bc2cpp-profiler-results.md) and
[ADR 0344](adr/0344-bc2cpp-profiler-block-results.md).

### The Fixnum proof on a native arm's Integer argument (ADR 0358)

Fresh census on this tree (all three engine gems, `RPG2k*`/`Game*` owners in
parentheses), shipped pass, `3rd/*` populated. The nine removals are the
`BC2CPP_NATIVE_INT_GUARDS=0` control against the default, one tree, same method:

| Measure | Control | Enabled |
| --- | ---: | ---: |
| `bc2cpp_send` call sites, all gems | 2,343 | 2,334 |
| of them in `RPG2k_*`/`Game_*` | 1,553 | 1,544 |
| `NATIVE_DIRECT_EXACT` arms keeping an `mrb_integer_p` test | 26 | 17 |
| `bc2cpp_getidx` / `setidx` / `slow_*` / `eqq` callers | unchanged | unchanged |

No helper gained a caller, so all nine are removals: `z=` 6, `x=` 2, `flash` 1.

Where the remaining 1,544 engine sites sit, by exclusive category:

| Category | Sites |
| --- | ---: |
| `core_tag_chain_else:receiver_other` | 589 |
| `rgss_native_exact_class_else` | 187 |
| `core_tag_chain_else:receiver_is_ivar` | 184 |
| `closed_world_kept:core_or_native` | 165 |
| `other:numeric_tag_guard` | 99 |
| `closed_world_kept:singleton_definer` | 81 |
| `other:no_guard_nearby` | 66 |
| `poly_diag:dynamic_single_registered_definition/receiver_class_unresolved` | 61 |
| `known_class_arm_still_by_name` | 34 |
| everything else | 78 |

`core_tag_chain_else:receiver_other` is the largest lever left and is a
receiver-class problem, not an argument one: `empty?` 160, `to_s` 139, `size` 70,
`length` 49. Its receiver-origin heuristic splits `register_copy` 291,
`direct_call_result` 110, `indexed_result` 75, `unknown` 35 — and the first of
those is a text heuristic that a register `MOVE` hides, so the real split is not
yet measured.

Two categories are known over-conservative rather than genuinely dynamic:
`closed_world_kept:singleton_definer` (81, all `width`/`height`/`row`, from the
`class << Graphics` body in mruby-rgss/mrblib/lib.rb:1558) and
`closed_world_kept:core_or_native` (165, where `@outside_names` is class-blind
and unrelated mruby gems registering a name refuse the engine's own class).
Neither is measurable without building its proof.

The `core_tag_chain_else` receiver-origin split is a floor, not an answer, and
its blind spot is worth naming before the next round picks a target: `register_copy`
fires on any register `MOVE`, and the emitter emits a `MOVE` for every Ruby local
assignment, block-parameter binding and block-result assignment. So those 291 sites
are an aggregate over several distinct Ruby-level origins, and reading them as one
root cause would misdirect the work. Making `receiver_origin` follow `MOVE` chains
is a measurement-only change to `tools/bc2cpp/site_census.rb` and would re-partition
them before anything is built.

Three shapes are worth naming because they are gaps rather than missing proofs:

* **A local receiver that a fresh allocation or an inlined `select`/`map` collector
  produced.** `Game::State#to_lsd` alone holds 13 `empty?` sites of this kind;
  `CHAINED_ARRAY_METHODS` already knows those calls return an Array, but
  `exact_core_value_class` never asks.
* **A method result whose receiver-specific return class exists but is refused.**
  `Game::Variables#to_h` returns `@data`, a Hash the class layout already knows;
  `codegen_return_classes.rb`'s `RETURN_CORE_CLASS` veto rejects the mask even
  though the scoped form is stricter than the name-wide one it falls back to.
* **A `Hash#[]` element.** `@ui[:skills]` in the battle scene is a RecordHash whose
  per-key value classes `RecordHash.analyze` already computes, but which is not an
  oracle for `element_index_mask`.

See [native arm Integer guards](bc2cpp-native-int-guards.md) and
[ADR 0358](adr/0358-bc2cpp-native-direct-exact-int-guard.md).

## Follow-up: closed-world helper else (ADR 0360)

Measured on the wio closed world (shipped pass) at master `0a9adfc`, helper emission only:

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 24 | 23 | -1 |
| generated callers of a helper that holds a by-name call | 5,781 | 5,509 | -272 |
| `bc2cpp_send` call sites in generated bodies | 2,408 | 2,408 | 0 |
| **Sites that can reach by-name dispatch** (bodies + helper callers + 417 block + 30 funcall sites) | **8,636** | **8,364** | **-272 (-3.1%)** |

`bc2cpp_slow_div` (272 callers) is the only helper whose operator is answered by Integer and Float alone
(`CallFacts::Answers#members`), so its else is now a proven NoMethodError. The ADR lists the answering
classes of every other helper name: `>>`, `round` and `^` need operand-coercion or object.c bodies, `+ - *` need
`Array`/`String` (and, in this scan, `Time`) bodies that are static in mruby, `< <= > >=` need the Comparable
includers, `[]`/`[]=` have thirteen native classes besides the eight registry ones.

## Follow-up: checked exact proofs in core bodies (ADR 0359)

The `receiver_other` core tag chain was not losing proofs through register copies: the flow and the
dominating walk already follow MOVEs. Its unproven receivers have an unknown source (ivar, argument, call
result, element, `x || []`). The one structural gap was that a compiled core body is compiled without the
engine's world, so its literal and `*rest` receivers were never proven. They are now proven under the
program world and **checked**: each site keeps one class test and its else is `bc2cpp_guard_violation`
(`GUARD_VIOLATION CORE_BODY_EXACT`), not an unguarded access. `BC2CPP_CORE_BODY_EXACT=0` disables it (the
output is then byte-identical to master).

Measured on the wio closed world (shipped pass), same tree, switch off against on:

| Measure | Off | On | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 2,321 | 2,286 | -35 |
| `mrb_funcall_with_block` sites in generated bodies | 417 | 414 | -3 |
| `bc2cpp_guard_violation` call sites (all families) | 310 | 348 | +38 |
| `CORE_BODY_EXACT_CHECKED` sites (35 `CLOSED_WORLD_NATIVE_EXACT`, 3 `BLOCK_CORE_DIRECT`) | 0 | 38 | +38 |

The unguarded version of this change removed the same sites, so the check costs the class test and 38 cold
violation arms, not the gain. See [ADR 0359](adr/0359-bc2cpp-exact-proofs-in-core-bodies.md).

## Follow-up: closed `+` and `*` helpers (ADR 0361)

Measured on the wio closed world (shipped pass) at master `9361f234`. The census scan now skips the by-name copy that a
closed helper keeps under `#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)` (wio never defines them), so the
`/` helper of ADR 0360 no longer counts either:

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 23 | 21 | -2 |
| generated callers of a helper that holds a by-name call | 5,509 | 4,355 | -1,154 |
| `bc2cpp_send` call sites in generated bodies | 2,321 | 2,321 | 0 |
| **Sites that can reach by-name dispatch** (bodies + helper callers + 417 block + 30 funcall sites) | **8,277** | **7,123** | **-1,154 (-13.9%)** |

`bc2cpp_slow_add_f` (712 callers) and `bc2cpp_slow_mul_f` (442) switch on Integer, Float, String and Array tags and raise the
proven NoMethodError for any other receiver. `bc2cpp_slow_sub_f` (471) stays: `Array#-` (mruby-array-ext) is a hash walk
with no entry point to mirror, and Time answers `-` wherever mruby-time is linked.

## Follow-up: closed comparison helpers (ADR 0362)

`bc2cpp_slow_lt`/`le`/`gt`/`ge` (296 + 134 + 311 + 166 generated callers) now carry a closed form beside the by-name
helper (the latter under `#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)`). Wio closed world, shipped
pass, master `9361f234` against the branch, with the census counting only the live arm of a helper written twice
(see the combined section below for the census fix that makes that hold for nested `#if`):

| Measure | Before | After |
| --- | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 23 | 23 |
| generated callers of a helper that holds a by-name call | 5,509 | 5,509 |
| `bc2cpp_send` call sites in generated bodies | 2,321 | 2,321 |

The headline number does not move: the closed form of each helper still holds one by-name call, for a **Hash**
receiver, because `Hash#<` is Ruby over `==` of the stored values (mruby-hash-ext). What changed is which receivers
can reach it: before, every non-number (String, Symbol, nil, any object) dispatched by name; now only a Hash does,
and every other receiver is a proven NoMethodError or Comparable's body computed in C++. The closed form's Hash call
sits beside the unchanged `#if` copy, which the census does not count. Closing the last arm needs a per-element
`==` proof or a compiled `Hash#<` reachable from the helper's translation unit.

## Follow-up: core-body helper closure (ADR 0364)

Measured on the wio closed world (shipped pass) at master `9361f234`; the `#if` arm kept for Complex/Rational builds
is stripped from both runs, as ADR 0360 counted `/`.

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 23 | 19 | -4 |
| generated callers of a helper that holds a by-name call | 5,509 | 5,483 | -26 |
| `bc2cpp_send` call sites in generated bodies | 2,321 | 2,321 | 0 |

`bc2cpp_slow_xor` (4 callers), `bc2cpp_slow_rshift` (17) and `bc2cpp_slow_round` (5) mirror the bodies of Integer,
nil/true/false and Float inside the helper. `& | << % -@ zero? ===` stay open: their member sets contain a static
body that public API cannot reproduce (Array, String, IO), Ruby definers, or are unbounded (ADR 0364 lists each).

## Combined: ADR 0360, 0361, 0362 and 0364 together

The helper keys are independent (`add`/`mul` 0361, `lt`/`le`/`gt`/`ge` 0362, `xor`/`rshift`/`round` 0364, `div`
0360), so one shipped pass shows every closure at once. Wio closed world, shipped pass, master `9361f234` against
the combined tree, both measured with the same census. The census now also keeps a helper's own `#ifdef` and
`#else` inside the by-name copy from ending its mask early: `bc2cpp_slow_rshift`'s by-name copy has
`#ifdef MRB_USE_BIGINT ... #else return bc2cpp_send(...)`, and that inner `#else` used to leave one `>>` call live and
attributed to the `round` helper.

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 23 | 17 | -6 |
| generated callers of a helper that holds a by-name call | 5,509 | 4,329 | -1,180 |
| `bc2cpp_send` call sites in generated bodies | 2,321 | 2,321 | 0 |
| **Sites that can reach by-name dispatch** (bodies + helper callers + 417 block + 30 funcall sites) | **8,277** | **7,097** | **-1,180 (-14.3%)** |

The five helpers that left the list (six by-name calls, `rshift` held two) are `bc2cpp_slow_add_f` (712 callers),
`bc2cpp_slow_mul_f` (442), `bc2cpp_slow_rshift` (17), `bc2cpp_slow_xor` (4) and `bc2cpp_slow_round` (5). The
comparison helpers stay listed with their one Hash call.

## Follow-up: what remains after ADRs 0360-0368, and module singleton arms (ADR 0369)

Measured at master `c973a581` (PRs #2044-#2046 merged), wio closed world, shipped pass, the same tree before and after
(`3rd/mruby`, `mruby-marshal`, `mruby-onig-regexp` and `mruby-stringio` populated; a run without the last one lacks the
`StringIO` bodies and reads 2,236 sites).

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 2,286 | 2,205 | -81 |
| `bc2cpp_send` calls held in helpers | 17 | 17 | 0 |
| `bc2cpp_nomethod` sites | 4,460 | 4,541 | +81 |
| `closed_world_kept: singleton_definer` | 91 | 10 | -81 |
| callers of a helper holding a by-name call | unchanged | unchanged | 0 |

All 81 are removals (`width` 47, `height` 33, `transition` 1): the one singleton definer of those names is
`RGSS::Graphics`, a module, and the chains already listed every instance definer. The else is a `bc2cpp_nomethod`
behind an identity arm (`mrb_type == MRB_TT_MODULE && mrb_class_ptr == RGSS::Graphics`), 63 new
NOMETHOD_REVIEWED keys. The 10 left (`action` 3, `wait` 3, `row` 3, `term` 1) are singleton definers on class objects.

### Remaining sites, by name and by reason (2,286 before the change)

By name: `[]` 208, `empty?` 202, `size` 176, `to_s` 151, `length` 69, `new` 66, `to_enum` 66, `to_i` 60, `[]=` 51,
`push` 50, `width` 47 (now 0), `x=` 44, `y=` 44, `update` 42, `include?` 37, `name` 37. 241 names remain; the top five
(`[]`, `empty?`, `size`, `to_s`, `length`) are 806 sites. Of the 2,286, 80 sit in the RGSS probes
(`effect_probe`, `audio_probe`, `probe_wav`, ...) that `scripts/strip_wio_rgss_probes.rb` deletes from the real wio build:
the census counts them, the shipped binary does not.

By reason, with the proof each one needs (the receiver class sets come from the exact-class flow):

| Reason | Sites | Why the receiver is unproven | The proof that would close it |
| --- | ---: | --- | --- |
| core tag chain else, receiver not an ivar | 814 | register copy 658, direct-call result 206 (project getters and `LCF` readers whose result class set is a union with an unpooled return), `GETIDX` element 61+ (elements of containers filled by `map`/masgn/parsed data) | element and tuple-slot classes of the container (ADR 0312 measured it as the dominant unknown); return-class sets for getters over `@x \|\| []` stores |
| core tag chain else, receiver is an ivar | 215 | `@list` (22) is stored from a parameter (`commands \|\| []`) and from `@list, @index, @id = @call_stack.pop`, a tuple slot of another ivar's element; `@actors` from `map { @roster[i] }.compact` | argument pools for `start(commands)` plus tuple-slot typing of `@call_stack` elements; `map` over an unproven receiver is not an Array while a user-defined `map` exists |
| RGSS native exact-class else | 206 | the receiver is proven (`Sprite`, `Window`); an argument (`x=`, `y=`) is not provably an Integer | argument-shape propagation across call edges (ADR 0358 does the call-local part) |
| `core_or_native` | 186 | `name` 37, `delete` 18, `map` 17, `resume` 11: a native or core definer the world cannot exclude, receiver unproven | an exact receiver class per name |
| `receiver_class_unresolved` (POLY_DIAG) | 210 | `inspect` 28, `call` 14, `<=>` 12, procs and user objects | inherent |
| `implicit_self_unresolved` | 194 | `to_enum` 66: `Kernel#to_enum` lives in mruby-enumerator, whose bodies stay interpreted (Fiber and closures), so there is no direct target whatever the receiver | not closable by analysis; needs a compiled enumerator body |
| numeric tag guard | 121 | `[]` behind an Integer test, the receiver is an exact Array/Hash and the index is not provably an Integer | the index-body helper work (not analysis) |
| `no_guard_nearby` | 95 | `to_f` 20 (a Float-only arm, the Integer registration is not a derived expression), `===` 11 in core bodies (`Array#deconstruct`), `abs` 17 | an Integer `to_f` arm only moves the line, a receiver proof removes it |
| `singleton_definer` | 91 to 10 | a module singleton definer is not an instance of any listed class | ADR 0369 |
| `dynamic_install` | 29 | `update`: a runtime definition site can install the name | per-class resolution of the installer |

Judged not worth doing (or unsound) as analysis changes: widening `direct_callable?` to `&block` bodies (ADR 0341: one
site); arming class-object singleton definers the same way (10 sites left, and a class object has class-side
inheritance, so each subclass needs its own arm); dropping the probe sites by analysis (they are stripped by the build,
the census should read the stripped source instead).

## Follow-up: exported core bodies (ADR 0367)

`bc2cpp_slow_mod` (138 generated callers, two by-name calls) and `bc2cpp_slow_neg_f` (71 callers, one) carry a closed
form that calls bodies `patches/mruby-expose-misc-bodies.patch` exports (`Integer#%`, `Float#%`, `String#-@`, the
sprintf formatter). Wio closed world, shipped pass, branch base `b4efe59e` (PR #2045's head) against the branch, the
`#if` arm for Complex/Rational builds stripped from both runs as before:

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 17 | 14 | -3 |
| generated callers of a helper that holds a by-name call | 4,331 | 4,122 | -209 |
| `bc2cpp_send` call sites in generated bodies | 2,306 | 2,306 | 0 |
| **Sites that can reach by-name dispatch** (bodies + helper callers + 414 block + 30 funcall sites) | **7,081** | **6,872** | **-209 (-3.0%)** |

The generated method bodies are byte-identical (only the two helpers changed). What stays open, and why:

| Helper | Callers | Held by-name call | Why it cannot close exactly |
| --- | ---: | --- | --- |
| `bc2cpp_slow_zero` | 33 | `zero?` | `Numeric#zero?` is `self == 0`: any Numeric that is not an Integer or Float dispatches `==` by name |
| `bc2cpp_slow_lt` `le` `gt` `ge` | 908 | `Hash#<` ... | Ruby over `all?`, `key?` and `==` of the stored values; `mrb_equal` differs for NaN and a user `==` |
| `bc2cpp_eqq` | 110 | `===` | `Kernel#===` answers every object; Data (Regexp) and Proc `===` are static in other gems |

## Index helpers closed (ADR 0365)

`bc2cpp_getidx`, `bc2cpp_getidx0` and `bc2cpp_setidx` no longer hold a by-name call: 2,017 + 32 + 348 generated callers stop
reaching by-name dispatch, helper-held by-name calls go from 19 to 16 and `bc2cpp_send` in the helper region from 17 to 14
(shipped wio pass, base `b4efe59e`). Bodies and nomethod sites are unchanged (2,286 and 4,460).

## Follow-up: exported collection bodies (ADR 0366)

`patches/mruby-expose-collection-op-bodies.patch` exports `Array#-`, `#&`, `#|` (mruby-array-ext), `String#<<`
(mruby-string-ext) and `IO#<<` (mruby-io), and the `- & |` helpers now call them instead of dispatching by name.
Wio closed world, shipped pass; "before" is master `da29f561` (ADR 0365 and 0367 merged) over an mruby tree with the
misc and index patches only, "after" the branch over all three. The generated method bodies are identical (0 methods
differ once symbol and send indices are normalised).

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 11 | 8 | -3 |
| helpers that hold a by-name call | 10 | 7 | -3 |
| generated callers of a helper that holds a by-name call | 1,723 | 1,172 | -551 |
| `bc2cpp_send` call sites in generated bodies | 2,205 | 2,205 | 0 |
| **Sites that can reach by-name dispatch** (bodies + helper callers + 414 block + 30 funcall sites) | **4,372** | **3,821** | **-551 (-12.6%)** |

The three removals are `bc2cpp_slow_sub_f` (471 callers), `bc2cpp_slow_and` (66) and `bc2cpp_slow_or` (14).
`bc2cpp_slow_lshift` (122) stays: the wio world has two more `<<` definers, `RGSS::ErrorReport::Tee#<<` (compiled
Ruby) and `Enumerator::Yielder#<<` (interpreted Ruby of mruby-enumerator), and the second has no compiled body to call.
The closed `<<` form is generated, and proven against the real operators, in worlds without such a definer. Builds that
link mruby-time (psp, maix, desktop) keep `-` open because `Time#-` is static.

## Follow-up: the Hash arm of the comparison helpers through compiled core (ADR 0371)

`bc2cpp_slow_lt`/`le`/`gt`/`ge` (296 + 134 + 311 + 166 generated callers) no longer hold a by-name call in a closed world
that compiles mruby's own Ruby: the Hash branch calls the compiled `Hash#<` family behind an exact-Hash test.
Wio closed world, shipped pass, same tree with `BC2CPP_CORE_COMPILED_CMP=0` as the base (the `#if` arm for
Complex/Rational builds stripped from both runs):

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 17 | 13 | -4 |
| generated callers of a helper that holds a by-name call | 4,329 | 3,422 | -907 |
| `bc2cpp_send` call sites in generated bodies | 2,205 | 2,205 | 0 |
| **Sites that can reach by-name dispatch** (bodies + helper callers + 414 block + 30 funcall sites) | **6,978** | **6,071** | **-907 (-13.0%)** |

The three shipped closed builds (wio, psp, maix) are hot-only and hold no core Ruby, so the arm exists only in the
census world and in a closed build with `BC2CPP_HOT_ONLY=0`. Core compile counts are unchanged (215 core-source methods,
190 compiled, 25 interpreted; the compiler now prints the 25 with their reasons). Still open: `zero?` (33, the receiver
set is unbounded because `File.zero?`/`FileTest.zero?` are native class methods), `===` (110), `&` `|` `<<` `-` and the
index helpers when the index-body patch is absent.

## Follow-up: the `zero?` helper through compiled core (ADR 0374)

`bc2cpp_slow_zero` (33 generated callers) no longer holds a by-name call in a closed world that compiles mruby's own Ruby: every
Numeric that is not a Float runs the compiled `Numeric#zero?` (its `==` is the body's own site), `File`, `FileTest` and `File`
subclasses raise the `File.zero?` argument error (the helper has no argument), and every other receiver is a proven NoMethodError.
Wio closed world, shipped pass, base `38f7267a` (master after ADR 0371), the `#if` arm for Complex/Rational builds not counted:

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` calls held in helpers | 13 | 12 | -1 |
| generated callers of a helper that holds a by-name call | 3,423 | 3,390 | -33 |
| `bc2cpp_send` call sites in generated bodies | 2,184 | 2,183 | -1 |
| `bc2cpp_nomethod` sites | 4,539 | 4,540 | +1 |
| **Sites that can reach by-name dispatch** (bodies + helper callers + 414 block + 30 funcall sites) | **6,051** | **6,017** | **-34 (-0.6%)** |

The body delta is the scan change that came with it: a name that native sources spell only as class-level registrations
(`start` is `GC.start`) is attributed to its class object instead of left unbounded. The shipped firmware closed builds are
hot-only and hold no core Ruby, so none of this applies there; it is the census world and `BC2CPP_HOT_ONLY=0` builds. Still
open: `===` (110), `&` `|` `<<` `-` and the index helpers when their body patches are absent; `implicit_self_unresolved` is 198
body sites (88 + 82 + 27 + 1 by registered-definition path).

## Follow-up: checked setter-site pools (ADR 0370)

`BC2CPP_SETTER_POOLS=0` against the default, wio closed world, shipped pass; the off run is `cmp`-identical to the tree
without the change on both trees. PR #2050's identity arms for module singleton definers (ADR 0369) removed the
`singleton_definer` elses the pools' `width`/`height` arms also shed, so the gain is measured before and after it:

| Measure | Branch point `8ab8aa75` off | on | Delta | master `16e2bc43` off | on | Delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 2,286 | 2,259 | -27 | 2,208 | 2,197 | -11 |
| `mrb_funcall_with_block` | 414 | 414 | 0 | 414 | 414 | 0 |
| `bc2cpp_nomethod` sites | 4,460 | 4,458 | -2 | 4,541 | 4,539 | -2 |
| `CHECKED_POOL_EXACT` arms (class test, nil arm, guard-violation else) | 0 | 25 | +25 | 0 | 9 | +9 |

Body `bc2cpp_send` sites by name, the ten largest and every name that changed, branch point (the ten largest do not move
on either tree):

| Name | Off | On | Delta |
| --- | ---: | ---: | ---: |
| `[]` | 208 | 208 | 0 |
| `empty?` | 202 | 202 | 0 |
| `size` | 176 | 176 | 0 |
| `to_s` | 151 | 151 | 0 |
| `length` | 69 | 69 | 0 |
| `new` | 66 | 66 | 0 |
| `to_enum` | 66 | 66 | 0 |
| `to_i` | 60 | 60 | 0 |
| `[]=` | 51 | 51 | 0 |
| `push` | 50 | 50 | 0 |
| `width` | 47 | 34 | -13 |
| `x=` | 44 | 42 | -2 |
| `y=` | 44 | 42 | -2 |
| `height` | 33 | 30 | -3 |
| `name` | 37 | 35 | -2 |
| `clear` | 7 | 5 | -2 |
| `blt` `fill_rect` `text_size` | 7 + 7 + 4 | 6 + 6 + 3 | -1 each |

On master `width` and `height` have no by-name site left, off or on, and every other changed row is identical (-11 in all). By
category on master: `rgss_native_exact_class_else` 206 to 197, `closed_world_kept:core_or_native` 188 to 186; the two
`core_tag_chain_else` rows (820 and 216) do not move. Element, tuple-slot and argument-Integer typing are not built
(ADR 0370, Context).

## Follow-up: splatted `blk.call(*args)` on a core block (ADR 0373)

Wio closed-world shipped pass, master `38f7267a`, before and after. All 28 by-name `"call"` sites in generated bodies
(`mrb_funcall_argv(M, r, "call", RARRAY_LEN, RARRAY_PTR)`, the else arm of CORE_PROC_CALL's runtime-sized splat) were in
`Enumerable` block bodies of mruby's `enum.rb`: 26 `block.call(*val)` on the method's own `&block` (22 methods) and 2
`yield(*val)` in `Enumerable#cycle` (a `BLKPUSH`). Each is now a `mrb_proc_p` arm that yields with the Array's length and
elements, and a `bc2cpp_nomethod` else.

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| by-name `"call"` sites in bodies | 28 | 0 | -28 |
| `mrb_funcall` / `_argv` / `_id` in bodies | 30 | 2 | -28 |
| `bc2cpp_nomethod` sites | 4,539 | 4,567 | +28 |
| `bc2cpp_send` sites in bodies | 2,197 | 2,197 | 0 |

| Receiver | Sites | Result |
| --- | ---: | --- |
| method's own `&block` through `GETUPVAR` (BLOCK_PARAM_CALL proof) | 26 | closed |
| `BLKPUSH` (`yield *val`) | 2 | closed |
| stored callable, `Method`, plain parameter | 0 | none with a runtime-sized splat |

The two remaining body `mrb_funcall*` sites are not `call`. Core bodies exist only in this measurement world and in a
`BC2CPP_HOT_ONLY=0` closed build, so the shipped firmware is byte-identical.
