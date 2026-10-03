# 0331. bc2cpp: receiver class proofs for the unproven by-name sends, measured and not built

Date: 2026-10-03

## Status

Accepted (a decision not to build; revisit if a trigger below fires)

## Context

ADR 0325 and the 2026-10-02 baseline end on the same finding: the by-name sends that remain in the engine gems are
mostly sends whose receiver class set is *unproven*, not sends a mechanism could not remove. ADR 0325 listed the
producers of the unproven receivers of block sends (call results 76, `x || []` merges 49, `GETIDX` elements 47,
arguments 37); ADR 0307, 0309, 0312 and 0313 measured pieces of the same population. This ADR measures the whole of it
once, by source, with the counterfactual done by the real code generator instead of a model: for every engine send that
still dispatches by name and whose receiver is not proven, what happens to its by-name lines if the receiver class set
*were* proven, and what the proof would have to establish. The cutoff for building is at least 30 by-name sends removed
in the engine gems, kill switch off against on, on one tree.

## Method

`BC2CPP_RECEIVER_PROOF_REPORT=<tsv>` (`tools/bc2cpp/receiver_proof_report.rb`, aggregated by
`scripts/bc2cpp_receiver_proof_report.rb`) writes one row per explicit-receiver send of the engine gems
(`mruby-rpg2k`, `mruby-lcf`, `mruby-rgss`) whose shipped code holds a by-name line. Per row: the nearest writer of the
receiver register (`call`, `ivar`, `argument`, `element`, `const`, `upvar`, `merge` for a literal written on one arm of a
join, `other`) and the reason that writer has no class set (the unmodelled returns of the callee's definitions, the
class pool state of the ivar or parameter, the other arm of the merge).

The counterfactual recompiles the one send in a forked child with the receiver forced to a class set and counts the
by-name lines again, so "removed" is what the actual consumers (exact core arms, native wrappers, NILABLE_RECEIVER,
guard chains, `ClosedWorld#refusal`) do with a proven set. Two sets, each forced without and with nil (a merge never
holds nil):

* `own`: the set the source's data suggests (a merge is Array; a call result is the join of the classes the callee's
  definitions return, plus an assumed class for a native definition the table has no fact for, `to_s` String, `keys`
  Array, `parameters` Array, `snap_to_bitmap` RGSS::Bitmap; an ivar is its pool);
* `floor`: every class that answers the name. A line that goes at the floor goes whatever set is proven, so it is the
  number that does not depend on how good the proof is.

Both are ceilings on what a proof is worth, not results: the forced register ignores every other writer of the value
the real flow would still have to join (a prototype below measured half of the own-set number).

The fork is what keeps the report output-neutral: a recompile leaves memos behind (the direct-entry decision of a
block, for one) that changed seven `any?` block sends the first time the recompile ran in the build process.
`shipped.cxx` of the master tree and of the same tree with the report on are byte-identical (`cmp`), and
`scripts/bc2cpp_receiver_proof_report_check.rb` asserts it on a fixture. Wio closed world, `3rd/*` populated, host
`mrbc` prebuilt, `LANG=C.UTF-8`, master `eed615c7`; the shipped pass is the only pass reported (about 390 s of wall time
on this machine against about 230 s without the report).

## Results

1,970 engine sends hold a by-name line (2,030 lines). 187 already have a proven receiver set and still dispatch (the
consumer has no arm for the class: the subject of ADR 0323, PR #1998 and ADR 0325's 172 sends, not this one). **1,783
have an unproven receiver (1,841 lines).**

| Source | Sites | Own set | Own removes (nil-free / nil allowed) | Floor removes (nil-free / nil allowed) | Risk tier | Floor (nil allowed) per risk |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| call result | 491 | 161 | 114 / 110 | 73 / 71 | 2 | 35.5 |
| ivar | 322 | 8 | 8 / 8 | 69 / 66 | 3 | 22.0 |
| argument | 321 | 1 | 0 / 0 | 55 / 53 | 3 | 17.7 |
| `GETIDX` element | 234 | 0 | - | 6 / 6 | 3 | 2.0 |
| constant | 164 | 0 | - | 0 / 0 | 2 | 0 |
| other (`rescue` nil, `aref`, `sub`) | 119 | 0 | - | 5 / 3 | 3 | 1.0 |
| `x \|\| []` merge | 85 | 85 | 75 / 75 | 1 / 1 | 2 | 0.5 |
| captured local | 47 | 0 | - | 11 / 4 | 2 | 2.0 |
| **total** | **1,783** | **255** | **197 / 193** | **220 / 204** | | |

Of the 161 call-result own sets, 71 rest on an assumed class for a native definition (58 of the 114 removals): the
table itself has 90 sites and 54 removals without that assumption.

The risk tier is a judgement, not a measurement: 1 a local fact of the method, 2 a fact about the producer of a value,
3 a whole-program fact or the contents of a container (a parameter has no visible caller set, an ivar is open to natives
and reopens, an element is a mutable container's slot, ADR 0312). Ranked by removable sends per unit of risk the floor
gives call results (35.5), ivars (22.0), parameters (17.7) and nothing else above 2.0; the own sets give call results
(55), merges (37.5), then ivars (2.7), and every one of those numbers is conditional on a proof that does not exist.

What stops the floor from freeing the rest (the first blocker, sites):

| Source | freed | a native cell | a non-direct Ruby body | an ivar accessor cell | name unbounded (a dynamic definer) | no instance class answers | a gate other than a cell |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| call result | 71 | 336 | 2 | 18 | 54 | 6 | 4 |
| ivar | 66 | 213 | 1 | 17 | 11 | 0 | 14 |
| argument | 53 | 212 | 1 | 5 | 47 | 0 | 3 |
| element | 6 | 135 | 4 | 10 | 77 | 2 | 0 |
| constant | 0 | 14 | 0 | 0 | 73 | 77 | 0 |
| other | 3 | 87 | 4 | 2 | 18 | 3 | 2 |
| merge | 1 | 69 | 0 | 0 | 15 | 0 | 0 |
| captured local | 4 | 29 | 3 | 0 | 9 | 2 | 0 |

"A native cell" means one of the classes that answer the name defines it natively with no frame-independent entry
(`empty?` on `String`, `each` on `Range`): it blocks the *floor*, not a proof that names Array. Nil is not the blocker
it first looked like: allowing it moves the own removals from 197 to 193 and the floor from 220 to 204, because
NILABLE_RECEIVER (ADR 0296) compiles the non-nil path as an exact receiver. The 204 sites the floor frees are 100
`width`/`height` on RGSS wrappers (Game::Map, Bitmap, Sprite, Window), `actor` on `Game::Battle::Combatant`/`EquipMenu`
17 and a handful of others.

**Where the unproven receivers come from** (the root, not the nearest writer):

* **Ivars (322 sites, 8 pooled).** 235 sites read an ivar whose class pool was dropped by a store that is unmodelled,
  by the stored value's producer: a parameter (`@parent`, `@enemies`, `@map_animation_interp`), a call (`@state`,
  `@list`, `@actors`, `@call_stack`: `map`, `compact`, `select`, `dup`, `uniq`, `reject` results), a `||` merge
  (`@commands`, `@items`). 54 are structural because a native source spells the name, 9 a poisoned name, 9 an attr
  writer. The 8 pooled ones (`@interpreter`, Game::Interpreter) join another unmodelled writer at the site.
* **Call results (491).** 244 producing calls have an unproven receiver, 173 are implicit-self calls, 27 resolve to a
  definition with an unmodelled return, 27 to no definition; **per-class resolution of the callee leaves 0 sites with a
  complete return set**. The unmodelled returns of the callee's definitions are 207 sites through an ivar accessor (the
  pool problem above: `actors`, `map`, `contents`, `bitmap`), 136 through a native result (`to_s`, `keys`,
  `parameters`, `snap_to_bitmap`, `now`, `new`, `dup`), 130 through another call (`map`, `select`), 29 through an
  element, 20 with no definition at all (`reject`). In 108 sites the native is the only unmodelled definition.
* **Arguments (321).** 173 parameters are not pool candidates (no visible caller, an escaping entry), 147 are
  candidates whose pool was dropped by an unmodelled argument at some call site (call result 44, another parameter 40,
  element 15, ivar 6, upvar 8).
* **`x || []` merges (85).** The literal arm is Array in 72 (String 9, Hash 4); the other arm is an element of a
  container 37, a call 27 (`states` 9), a parameter 14, an array literal 5, an ivar 1. A merge adds nothing of its own:
  it is proven exactly when its other arm is, so it is not a source, it is the sum of the others. Forced to Array, 75 of
  the 85 lose every by-name line (the other 10 meet a native cell): the ceiling a proof of the other arm buys.
* **Elements (234)** and **constants (164)** have no hypothesis: element classes are ADR 0312's finding, and the
  constant receivers are class or module objects (77 with no instance class answering, 73 names a dynamic definer
  leaves unbounded).

Every source bottoms out on three roots: a parameter without a visible caller set, an ivar open to natives or fed by a
parameter, and a native result of a name with a user definition (`map`, `to_s`, `keys`, `new`).

### The largest follow-up, and why it was not built

`@contents` is the one root with a closed, sound-looking shape: 44 ivar sites (`DebugMenu` 21, `MapViewer` 12,
`ChipsetEditor` 8, `Scene::Base` 3), 38 of which the floor frees, 20 `contents` accessor call results (18 freed), 11
`bitmap` accessor results (11) and `@cursor_rect` 4 (4): about 70 sites. The scene classes store `Bitmap.new(..)` and
nil, so the pool would be `RGSS::Bitmap` or nil, but the name `@contents` is spelled by `mruby-rgss/src/lib.cxx`
(four `mrb_iv_get/set(M, self, ..)` calls for it, three more for `@cursor_rect`, in `window_init`, `window_refresh`,
`window_update` and their helpers), so
the pool of every class that has the ivar is dropped by name. Scoping the poison to the families those natives can
reach needs an audit that every native access names `self` of a function registered on a Window class, and that every
helper (`window_refresh` has 14 callers) is only called with its caller's `self`: a call-graph proof over 9,000 lines of
C++ that no existing audit (ADR 0302, 0314) does, and one a fixture cannot exercise because the RGSS natives are not in
the mruby test builds. It is the lever to build next, on its own.

### A prototype below the cutoff

The cheapest candidate the data pointed at was built as a prototype and measured, kill switch off against on, the same
tree (`shipped.cxx` pass of `scripts/bc2cpp_coverage_report.rb`, engine gems):

* ABSENT_NATIVE_DEFS: the registry holds a `<native>` placeholder for every name `NATIVE_SRCS` defines, whichever gems
  the build links, while `ClosedWorld` knows the natives that are really linked. A name no linked source spells has no
  native definition at run time (`cmd.parameters` is the attr_reader's Array where `Proc#parameters` is not built: the
  wio build links neither mruby-method nor mruby-proc-ext), so the placeholder was dropped from the return join:
  -7 `bc2cpp_send`.
* CORE_RESULT_FACTS: `Hash#keys` (`mrb_hash_keys`), `parameters` and `Graphics.snap_to_bitmap` as audited native result
  classes (registrations, spelling counts and the digest of each body pinned, plus a check that every `return` is built by
  `mrb_ary_new*`): -14 `bc2cpp_send` and -1 `mrb_funcall_with_block` (`keys` 5, `snap_to_bitmap` 9; `parameters` was
  dropped by its own audit in the wio world, where no source defines it).
* Both together: **-21 `bc2cpp_send` and -1 `mrb_funcall_with_block` in the engine gems, 22 by-name sends against a
  cutoff of 30**; `bc2cpp_nomethod` -4 (no provable error surfaced, none was added). With both switches at 0 the
  `shipped.cxx` was byte-identical to master (`cmp`).

The what-if of the same sources had predicted 32 (`keys` 10, `parameters` 14, `snap_to_bitmap` 8): half of `keys` and
half of `parameters` are consumers whose receiver the real flow still joins with another writer. The next tier of audited
names (`members` 3, `to_a` 4, `split` 2, `bytes` 2, and `to_s` 15, whose twelve-odd native definitions all need an audit)
would not close the gap with an audit each, so the prototype was dropped rather than shipped. The idea that survives it is
the second one: **a `<native>` placeholder of a name no linked source defines is not a definition**; it is sound on the
foundation every call-result proof already uses (`ClosedWorld#name_fully_visible?`), it is worth 7 sends today, and it
belongs with whichever change next touches the return table.

## Decision

**Nothing is built.** The cutoff is 30 removed by-name sends; the best sound slice measured 22. The other slices the task
named do not reach it:

* the only *complete* own sets (nothing unmodelled in the source) are 12 sites: 8 ivar reads of `@interpreter`, 3 call
  results (`build_timer_sprite`, `battle_status_window`) and 1 parameter;
* the merge slice (75 sites, the largest own number) needs its other arm proven, and the arms are elements (37), calls
  (27) and parameters (14): the same roots;
* per-class resolution of call results reaches 0 sites;
* the exact-Array element facts of literal arrays are ADR 0312's 28 reads, and a merge's element arm is a container
  slot (`h[k] || []`), not a literal array.

Hints are not proofs (ADR 0210, 0290): none was added.

## Consequences

* No generated code changes: there is no kill switch to measure and no removed-versus-relocated number from a build.
  The prototype's numbers above are the only build measurement; its code is not in this change.
* `BC2CPP_RECEIVER_PROOF_REPORT=<tsv>` and `scripts/bc2cpp_receiver_proof_report.rb` are the census for the next
  attempt; they load only when the variable is set and need the shipped pass (`SKIP_UNSUPPORTED=1`), or
  `BC2CPP_RECEIVER_PROOF_ANY=1` to include a fixture that is not an engine gem.
* `scripts/bc2cpp_receiver_proof_report_check.rb` (generated code only, about 30 seconds) runs in the `call-facts` shard:
  byte-identical output with the report on, and the rows of a fixture with a merge, an element, a parameter, an ivar
  dropped by a parameter store, a self call to an accessor and a proven literal.
* Not run, because nothing was built: no mutation check (the report changes no output, so there is no mutant to kill by
  assertion), no compiled-versus-interpreted comparison on full-core, core-only or 32-bit `mrb_int` builds, no
  withdrawal worlds beyond the fixture. The new Ruby is host-side tooling only; none of it is compiled by bc2cpp.

## Triggers to revisit

Run `BC2CPP_RECEIVER_PROOF_REPORT=rp.tsv MRBC=<host mrbc> ruby scripts/bc2cpp_coverage_report.rb > /dev/null`, then
`ruby scripts/bc2cpp_receiver_proof_report.rb rp.tsv`.

* A call-graph audit of the RGSS natives' `self` discipline lands (the `@contents`/`@cursor_rect`/`bitmap` rows above,
  about 70 floor-freed sites), or any other ivar name stops being poisoned by a native spelling.
* Parameter pools gain a source for the 173 non-candidates (a closed-world proof that an entry has no outside caller):
  the argument row is 53 floor-freed sites.
* A class-returning native result table covers more than `keys`/`snap_to_bitmap` (`to_s`, `to_a`, `members`) together
  with the absent-native rule: the call row's 136 native-result causes.
