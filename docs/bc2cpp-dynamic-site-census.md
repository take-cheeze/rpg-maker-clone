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

## Results (master at `f70fef67`, PRs #1947-#1962 merged)

The baseline is the same measurement on the tree before that round of work
(9,733 `bc2cpp_send` lines).

| Measure | Baseline | Now | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 9,730 | 5,081 | -4,649 |
| `bc2cpp_send` calls held in helpers | 3 | 24 | +21 |
| **`bc2cpp_send` total (what a text count sees)** | **9,733** | **5,105** | **-4,628 (-47.5%)** |
| `mrb_funcall_with_block` sites (`BLOCK_FALLBACK` markers 447) | 448 | 448 | 0 |
| `mrb_funcall` / `_argv` / `_id` in bodies | 28 | 28 | 0 |
| `mrb_funcall*` held in helpers | 2 | 5 | +3 |
| `bc2cpp_nomethod` sites (error raise, not dispatch) | 4,694 | 4,562 | -132 |

The three new helper-held funcalls are not dispatch in the shipped build: two
sit under `#ifdef MRB_UTF8_STRING` (String#size/length, ADR 0291; the project does
not define it) and one is the `puts` of the guard-violation error path.

### Relocated into helpers versus removed

A text count overstates the win, because most of the drop is a by-name call that
moved into a shared helper. Counting the generated sites that can still reach a
by-name call (their own `bc2cpp_send`, plus every call into a helper whose slow
arm dispatches by name, plus the block and funcall sites):

| | Baseline | Now |
| --- | ---: | ---: |
| Own `bc2cpp_send` in bodies | 9,730 | 5,081 |
| Calls into `bc2cpp_slow_*` (ADR 0292) | 0 | 3,542 |
| Calls into `bc2cpp_eqq` (ADR 0293) | 0 | 110 |
| Calls into `bc2cpp_getidx` / `getidx0` / `setidx` | 2,899 | 2,584 |
| `mrb_funcall_with_block` + body `mrb_funcall*` | 476 | 476 |
| **Sites that can reach by-name dispatch** | **13,105** | **11,793** |

* Of the 4,649 sites that left the bodies, **3,652 are relocated** (3,542 numeric
  operator sites now call 21 `bc2cpp_slow_*` helpers that hold 20 by-name calls,
  and 110 `===` sites call `bc2cpp_eqq`). They still dispatch by name for an
  operand or receiver class the helper does not own.
* **997 are truly removed**: 456 `===` sites and 55 `is_a?`/`kind_of?` sites
  became direct tests, 267 `:new` sites a direct construct, the rest typed or
  guard-violation arms (311 guard-violation calls, 246 guard-free `EXACT_TYPED`),
  and 8 numeric arms by NUMERIC_OPERAND_PROOF (353 to 361).
* The three index helpers are older relocations (OUTLINED_INDEX_OPS). The LCF row
  flow cut their callers by 315 (2,899 to 2,584); those were removed, not moved.
* Net effect on sites that can reach by-name dispatch: **-1,312 (-10%)**, against
  a text-count drop of -47.5%. The numeric helpers still make Integer/Float
  mixes cheap, because they do the Float arithmetic natively where the old else
  arm sent, so the relocation is a speedup even though it is not a removal.

### Where the remaining 5,081 sites sit

| Position | Sites | Share |
| --- | ---: | ---: |
| Else arm of an inline fast path (class or tag test above it) | 3,442 | 67.7% |
| Arm of a class the guard proves exactly, still by name | 1,198 | 23.6% |
| Bare dispatch, no guard at all | 441 | 8.7% |

Only 441 sites are "only dispatch". Everything else already has a typed or
tag-tested arm and keeps the send as its soundness fallback; removing it needs a
proof that the else is unreachable (ADR 0290 turns such an else into a
guard-violation raise).

### Top 25 method names

| # | Name | Now | Baseline | Cumulative share |
| ---: | --- | ---: | ---: | ---: |
| 1 | `[]` | 619 | 619 | 12.2% |
| 2 | `[]=` | 267 | 267 | 17.4% |
| 3 | `party` | 264 | 264 | 22.6% |
| 4 | `size` | 260 | 261 | 27.8% |
| 5 | `empty?` | 258 | 259 | 32.8% |
| 6 | `dispose` | 169 | 169 | 36.2% |
| 7 | `id` | 161 | 161 | 39.3% |
| 8 | `to_s` | 152 | 152 | 42.3% |
| 9 | `new` | 131 | 398 | 44.9% |
| 10 | `width` | 113 | 113 | 47.1% |
| 11 | `length` | 97 | 97 | 49.0% |
| 12 | `push` | 95 | 95 | 50.9% |
| 13 | `update` | 87 | 87 | 52.6% |
| 14 | `y=` | 87 | 87 | 54.3% |
| 15 | `x=` | 83 | 83 | 56.0% |
| 16 | `z=` | 68 | 180 | 57.3% |
| 17 | `to_enum` | 63 | 63 | 58.5% |
| 18 | `to_i` | 60 | 60 | 59.7% |
| 19 | `fill_rect` | 58 | 58 | 60.9% |
| 20 | `name` | 54 | 54 | 61.9% |
| 21 | `include?` | 53 | 53 | 63.0% |
| 22 | `max` | 51 | 51 | 64.0% |
| 23 | `draw_text` | 50 | 50 | 64.9% |
| 24 | `resume` | 45 | 45 | 65.8% |
| 25 | `screen` | 44 | 44 | 66.7% |

329 distinct names remain (363 before). Every operator name (`+ - * / % < > <= >=
<< >> & | ^ -@ zero? round`) went from 3,550 inline sends to 0, and `===` from 577
to 11. The remaining names are almost all untouched by this round.

### Why the sites are still dynamic (top categories)

Exclusive categories, largest first. "Estimate" is how many sites the named proof
could remove; it is a judgement from the site mix, not a measurement.

| # | Category | Sites | Share |
| ---: | --- | ---: | ---: |
| 1 | Core tag chain else, receiver not an ivar | 1,201 | 23.6% |
| 2 | Known-class arm, still by name | 1,198 | 23.6% |
| 3 | Core tag chain else, receiver is an ivar | 830 | 16.3% |
| 4 | RGSS native exact-class else | 628 | 12.4% |
| 5 | `CLOSED_WORLD kept: core_or_native` | 325 | 6.4% |
| 6 | `CLOSED_WORLD kept: singleton_definer` | 168 | 3.3% |
| 7 | `POLY_DIAG` genuinely dynamic (all sub-reasons) | 469 | 9.2% |
| 8 | No guard nearby (literal receivers) | 162 | 3.2% |
| 9 | `CLOSED_WORLD kept: dynamic_install` | 77 | 1.5% |
| 10 | Everything else | 23 | 0.5% |

**1. Core tag chain else, receiver not an ivar (1,201).** The site tests
`Array`/`Hash`/`String`/`Integer` tags inline and sends in the else:
`empty?` 227, `[]=` 187, `size` 185, `to_s` 152, `length` 95, `push` 56, `to_i`
53. Receiver origin: register copy 598, unknown 137, direct-call result 130,
other 109, indexed result 65, dynamic result 60, captured upvar 42. The proof is a
receiver class set (exact `Array`/`Hash`/`String`) carried through register
copies, return-class tables and arguments, so the else becomes a guard
violation. Estimate 300-450 sites. `to_s` (152) is interpolation of arbitrary
values and stays dynamic.

**2. Known-class arm, still by name (1,198).** The class is proven by the guard
and the arm still sends. Instrumenting `unlisted_class_call` for one run gave
the reason for each arm: 851 `lookup_unknown`, 260 `not_inherited_safe`, 86
`no_target`, 1 other.

* `lookup_unknown` (851): `closed_world_lookup_target` only accepts a single
  public definition with an `irep` for a non-self call. An `attr_reader` or
  `attr_writer` on the exact class has no `irep` (`id` 23 classes, `party`
  `ShopState` 127), and a `private` definition (`Game::Interpreter#party` 132,
  defined after `private` at `interpreter.rb:1233`) is a `NoMethodError` for an
  explicit receiver. Both are static facts about the exact class. Proof: reuse
  `ivar_accessor_call_code` for the exact class, and compile a private
  explicit-receiver call to its error. Estimate 750-850.
* `not_inherited_safe` (260): `inherited_lookup_safe?` refuses any name in
  `@outside_names`, which `dispose`, `x=`, `y=`, `contents=` are because the
  RGSS natives define them. `RPG2k3::Scene::Battle#dispose` (166) inherits a Ruby
  definition and no native sits on its chain. Proof: test the class's own
  ancestor chain for an outside definer instead of the global name. Estimate
  200-260.
* `no_target` (86, mostly `RPG2k3::Scene::Battle` methods): the lookup finds no
  definition for a class the chain still lists. Cause not established.

Combined estimate 950-1,100 sites, the largest single lever (about 19-22% of
what is left).

**3. Core tag chain else, receiver is an ivar (830).** `@ui` alone is 401 sites
(`[]=` 409 and `[]` 208 across the category), across 101 distinct ivars. `@ui`
is written twice (`scene/battle.rb:158` a Hash literal, `:4840` `nil`), so it is
`Hash` or `nil`, and the else is the nil `NoMethodError`. Proof: an ivar class
set of `{Hash, nil}` from the write set (no computed-name writer, ADR 0279),
with the else compiled to the nil error. Estimate 450-600 (`@ui` plus part of the
other 100 ivars). 596 ivars are currently "poisoned to unknown, OPAQUE" in the
coverage report, so more of this is fixable.

**4. RGSS native exact-class else (628).** 333 are an argument-tag else: the
receiver class is proven and the argument is not (`Bitmap.new(w, h)` 115, `x=`
62, `y=` 66, `z=` 68, `flash` 18). 295 are a receiver-class else for an
ivar-held native (`fill_rect` 58, `draw_text` 50, `blt` 40, `clear` 32,
`bitmap=` 31). Proofs: Integer facts for the direct entry's arguments
(NUMERIC_OPERAND_PROOF reaching the native-direct guard), and an exact native
class for the ivar. Estimate 250-400.

**5. `CLOSED_WORLD kept: core_or_native` (325).** The name has a core or
native definer the world cannot exclude (`name` 53, `resume` 45, `delete` 26,
`include?` 24, `map` 21, `index` 20). Proof: an exact receiver class for each
(for `resume`, a Fiber). Estimate about 100.

**6. `CLOSED_WORLD kept: singleton_definer` (168).** `width` 113 and `height` 41:
some definer is a singleton method, so any instance might carry one. Proof:
extend `exact_instances_singleton_free?` from the core classes to the project
classes. Estimate 100-168.

**7. `POLY_DIAG` genuinely dynamic (469).** `receiver_class_unresolved` 210,
`implicit_self_unresolved` 189 (`to_enum` 63, core mrblib self calls),
`traced_class_no_direct_target` 53, `chain/runtime_class` 16. Names are
`inspect`, `call`, `<=>`, `__to_int`, `read`, `send`: user objects, procs and
IO-like receivers. Mostly inherent. Estimate 100-180.

**8. No guard nearby (162).** `max` 51 and `min` 32 on a literal array
(`[a, b].max`), `to_f` 20, `abs` 17, `[]=` 17, `===` 11: 77 of these have a
literal or fresh receiver. A literal receiver is exactly its class, so the else
is dead. Estimate 120-140.

**9. `CLOSED_WORLD kept: dynamic_install` (77).** `update` 76: a runtime
definition site can install a method of that name (ADR 0288 resolves only
literal names). Proof: enumerate the installed names. Estimate 0-76.

Taking the estimates together, about 2,300-3,100 of the 5,081 sites (45-60%)
are removable with five proofs: the class-arm lookup fixes (2), `{Hash, nil}`
ivar sets (3), copy-propagated receiver classes (1), RGSS argument and receiver
facts (4), and literal receivers (8). The remaining 2,000 or so need
inter-procedural receiver typing or are genuinely polymorphic.

### Block and funcall sites

`mrb_funcall_with_block` has 448 sites. 340 are the dynamic else of a
`BLOCK_CORE_DIRECT` chain (`each` 183, `map` 41, `each_with_index` 40, `any?` 18,
`select` 13) and fall under category 1's proof. 73 are dynamic only (`each` 14,
`new` 12, `section` 9, `loop` 7, `open` 7, `times` 5). 35 are other fallbacks.
`BLOCK_FALLBACK` markers are unchanged at 447 because none of the proofs in this
round reaches block bodies. The `mrb_funcall*` sites in bodies are 28, mostly
literal-sized splat forwarding (`sprintf`, `puts`, `read`, `write`, `new`).

## Caveats

* This counts source sites, not executions. A site in a cold scene weighs the
  same as one in the frame loop; no profile is applied.
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
