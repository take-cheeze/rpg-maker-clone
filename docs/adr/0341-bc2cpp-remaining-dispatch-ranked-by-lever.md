# 0341. bc2cpp: where the remaining by-name dispatch actually is, ranked by structural lever

Date: 2026-10-04

## Status

Accepted (a census and a ranking; no mechanism built — see the triggers)

## Context

ADR 0331 ranked the unproven receivers by *risk tier* (how hard a proof would be) and by what a forced receiver class
set would free. ADR 0340 corrected its parameter row. Neither answers the question a reader actually has next: **which
single change removes the most by-name dispatch from the shipped build?** The two existing rankings are the wrong shape
for that — risk tier measures proof difficulty, not removable lines, and the `floor` column measures what a *receiver
proof* would free, which silently assumes the receiver proof is the bottleneck.

This ADR re-ranks the same census by **structural lever**: for each unproven site, what class of work would actually
remove its by-name line. That distinguishes a site whose receiver class is unknown (a proof is the bottleneck) from a
site whose receiver class is irrelevant because no direct call exists for the callee anyway (a codegen gap is the
bottleneck). ADR 0331's own `call` row — 439 sites, the largest — mixes both, which is why its floor number (67) is so
much smaller than its site count.

## Method

Same census as ADR 0331/0340: `BC2CPP_RECEIVER_PROOF_REPORT=rp.tsv MRBC=<host mrbc> ruby
scripts/bc2cpp_coverage_report.rb`, on master `921e1ee3` (ADR 0340 merged), 1,826 rows, 1,671 unproven, 1,728
unproven by-name lines. The report changes no generated code. Classification is by the columns the report already
carries, read in this order:

| Class | Test | Meaning |
| --- | --- | --- |
| `no_floor` | `floor_nil` is `-` | the name is unbounded or no class answers; no set frees it |
| `freed` | `floor_nil == 0`, `before > 0` | gone under *any* proven set — the pure proof bucket |
| `consumer_gap` | `floor_nil > 0` and `kinds` contains `absent`/`absent_or_native` | an answering class does not define the name in Ruby at all, so no direct call is possible |
| `other` | `floor_nil > 0`, no absent cell | a cell exists but is not direct-callable, or another gate |

`kinds` is the report's per-answering-class cell classification (`receiver_proof_report.rb:394-400`), and
`direct_callable?` (`codegen_send.rb:1835-1841`) is the predicate that decides `ruby_direct` vs `ruby_not_direct`.

## Results

**1,671 unproven sites, 1,728 by-name lines**, by structural lever:

| Lever | Sites | By-name lines | What removes them |
| --- | ---: | ---: | --- |
| `consumer_gap` | **1,046** | 1,050 | a direct-callable body for the callee (codegen), not a receiver proof |
| `no_floor` | 384 | 384 | nothing today: the name is unbounded or answers nothing |
| `other` | 69 | 122 | a per-cell codegen decision |
| `freed` | 172 | 172 | **a receiver class proof** — ADR 0312's element classes, ADR 0331's triggers |

So **the receiver-proof lever is 172 lines, and the codegen/consumer lever is 1,050** — six times larger. ADR 0331's
framing ("1,783 unproven; best sound slice 22 sends against a cutoff of 30") was measuring the smaller lever.

**The consumer gap is concentrated in block-only callees.** Of the 1,046, **880 call a callee with `argc == 0`** — one
that takes only a `&block`. The whole census is like this: **1,277 of 1,671 unproven sites (76%)** are a send of a
block-only callee (`each`, `map`, `each_with_index`, `first`, `name`, ...).

Two findings inside that, one dead end and one live:

* **Dead end: `direct_callable?` refusing a `&block` parameter.** `direct_callable?` requires
  `pure_mandatory_or_optional_arity?(irep)`, which is `enter_fields[2..].all?(&:zero?)` (`irep_arity.rb:249-255`) — and
  field 6 is the block. So `Array#each` (registered `MRB_ARGS_REQ(0) | MRB_ARGS_BLOCK()`, defined
  `def each(&block)`) is never direct-callable, and that is 98 sites on its own. **But it buys nothing:** of the 172
  `ruby_not_direct` sites, only **15** (27 lines) lack an `absent_or_native` cell, and only **one** of those is a
  block-only callee (`continue_game`). The other 97 `each` sites include `absent_or_native`, so even a perfect
  `direct_callable?` would leave them by-name. Widening the arity predicate is a codegen change to the `_impl` binding
  contract for **1 site**.
* **Live: `absent_or_native` is a whole-name fact where a per-class one is needed.** `rp_cell_lookup`
  (`receiver_proof_report.rb:394-400`) answers `absent_or_native` when `@closed_world.outside_names.include?(name)`
  and the class has no target — but `outside_names` (`closed_world.rb:675-705`) is built by scanning **every linked C
  source** for `mrb_define_*` literals and `MRB_SYM` tokens, with **no notion of which class** the registration was
  for. So one file anywhere registering `each` marks it absent for *every* class. For `each` the report's `cells`
  column shows exactly that: `Array=absent_or_native`, `Hash=absent_or_native`, with the other nine answering classes
  never consulted. `Array#each` **does** have a compiled Ruby body (`def each(&block)`,
  `3rd/mruby/mrblib/array.rb:15`, registered `MRB_ARGS_REQ(0) | MRB_ARGS_BLOCK()`), so the cell is wrong for the two
  classes that dominate this bucket. This is the **same over-collection** ADR 0340 found in admission rules 2/3 of the
  parameter pools (`entry_arg_call_index`'s `@outside_tokens`), now on the cell-lookup side.

  It is a genuinely scoped fix rather than a token tweak: the registration **is** class-scoped
  (`mrb_define_method(M, Array_class, ...)`), so the scanner has the class in hand at the point it records the name —
  what it does not keep is which class. Note mruby-compiler's own `MRB_SYM(each)` *call* (`codegen.c:4260`) is not
  the culprit: `core_native_srcs` (`compiled_gems.rb:240-245`) does not scan `mruby-compiler`.

  **How wide this is, honestly:** `each` is the one callee where the per-class cells were computed and the
  `absent_or_native` cell is demonstrably wrong for a class with a real Ruby body (`cells` reads
  `Array=absent_or_native|Hash=absent_or_native`). For the other large concentrations the `cells` column is `-`,
  because a site's own receiver hypothesis is unknown and the floor probe uses the `answerers` list instead — so the
  `empty?` (216) and `size` (140) buckets are *not* shown to be the same misclassification. They are the same
  `absent_or_native`-bearing kind, and the mechanism above would apply if their cells were computed, but this ADR has
  verified it only for `each`.

By callee, the largest consumer-gap concentrations are `empty?` (216), `size` (140), `each` (98), `length` (53),
`to_i` (52), `map` (50), `each_with_index` (39) and `name` (37) — and `Game::State#to_lsd` alone holds 7 of the 98
`each` sites.

## Decision

**Nothing is built.** The ranking is the deliverable: it says the next attempt should not be a receiver proof.

The obvious candidate — relaxing `direct_callable?` to admit a `&block` parameter, which looks like a 98-site win from
the `each` concentration — is measured here at **1 site**, and is rejected on that basis. Building it would have been
the wrong call on a plausible-looking number.

The `freed` bucket (172) is unchanged from ADR 0312/0331/0340 and still needs element classes; the `no_floor` bucket
(384) needs a name to answer at all, which is a different kind of work. The 1,046-site consumer gap needs a *scoped*
answer to "which outside sources can define this name for this class", not a global one.

Hints are not proofs (ADR 0210, 0290): no guard hint was added.

## Consequences

* No generated code changes, no kill switch; this is host-side analysis only.
* `scripts/bc2cpp_receiver_proof_report.rb` gains the structural-lever classification and prints it as a table, so the
  ranking is reproducible rather than asserted here.
* Not run, because nothing was built: no mutation check, no compiled-versus-interpreted comparison, no withdrawal
  worlds.

## Triggers to revisit

* **A scoped `outside_names` audit**: which linked native file spells `each`, and does it define it for any class the
  receiver can actually be? If a name's every spelling is a `MRB_MT_ENTRY` for a class no unproven receiver can be, the
  cell stops being `absent_or_native`. This is the one lever with >100 sites behind it, and it is the same shape as the
  per-name token refinement ADR 0340 lists for `outside_token`.
* **ADR 0312's element classes** — the `freed` bucket, 172 lines, unchanged since ADR 0331.
* **A direct-callable body for block-only core callees** (`each`, `map`, `each_with_index`): worth revisiting only if the
  scoped audit above shows those cells are genuinely `absent`, since with `absent_or_native` present the arm is not
  attempted at all and `direct_callable?` never runs.

Re-run with the commands in ADR 0340; the lever table is the first thing printed.
