# 0340. bc2cpp: the unproven parameter receivers are mostly block parameters, measured and not built

Date: 2026-10-04

## Status

Accepted (a decision not to build; revisit if a trigger below fires)

## Context

ADR 0331 measured 1,783 engine sends whose receiver class set is unproven and named the "argument" source as 321
sites, 55 of them floor-freed — the second-best row after call results by floor-per-risk (17.7). Its trigger said:
*"Parameter pools gain a source for the 173 non-candidates."* That sentence has been load-bearing ever since, and it
is **wrong in a way that matters**. It read the report's flat `no_candidate` value as one bucket.

`no_candidate` is not one thing. It is the union of every refusal in `entry_arg_candidates` (ADR 0295's admission
rules 1-8, `tools/bc2cpp/codegen_fixnum_proof.rb:735-766`) plus a category the rule table does not describe at all.
The compiler already has the enumerator — `numeric_root_not_admitted`
(`tools/bc2cpp/codegen_numeric_roots.rb:121-136`), written for `BC2CPP_NUMERIC_ROOTS` — and it was never wired to this
report. This ADR wires it, re-measures the bucket, and finds the largest part of it is not a parameter pool problem at
all.

## Method

`rp_argument_why` (`tools/bc2cpp/receiver_proof_report.rb`) now returns `no_candidate:<rule>` instead of
`no_candidate`, reading the rule through `numeric_irep_owner` and `numeric_root_not_admitted` — the same enumerator and
the same rule order, so the value is the compiler's own answer, not a re-derivation. Two categories no rule describes
are named separately: `native_entry` (a definition with no bytecode body, so no call site can be enumerated) and
`block_param` (below).

The measurement is `BC2CPP_RECEIVER_PROOF_REPORT=rp.tsv MRBC=<host mrbc> ruby scripts/bc2cpp_coverage_report.rb`,
aggregated by `scripts/bc2cpp_receiver_proof_report.rb`, on master `bf25f9cc`. Baseline before this change is
reproduced first and is unchanged in row count and by-name totals: 1,826 rows, 1,671 unproven, 1,728 unproven by-name
lines, against ADR 0331's 1,970/1,783/1,841 on its tree (within 6% on every row, as ADR 0331's own re-run
methodology anticipates).

The report changes no generated code, asserted by `scripts/bc2cpp_receiver_proof_report_check.rb` on a fixture
(`the report changes no generated code`) and in CI (`.github/workflows/build.yml`).

## Results

The argument bucket, 320 sites, split by the rule the method's pool candidacy fails:

| Rule | Sites | Floor-freed (nil allowed) | What a proof must establish |
| --- | ---: | ---: | --- |
| `block_param` | 91 | 21 | what the **callee of the iteration** yields |
| `dropped` | 146 | 34 | the producer of one unmodelled argument (ADR 0331's table) |
| `multidef2` | 33 | 11 | that the two definitions are the same method |
| `arity` | 22 | 3 | a wider arity admission rule |
| `multidef79` | 7 | 0 | 79 definitions |
| `outside_token` | 7 | 1 | that the token scan over-collected |
| `multidef6` | 5 | 0 | 6 definitions |
| `multidef3` | 3 | 0 | 3 definitions |
| `poisoned` | 3 | 0 | a per-name refinement of the poison set |
| `dynamic_name` | 1 | 0 | a per-name refinement of ADR 0279's universe |
| `multidef5` | 1 | 0 | 5 definitions |
| `pooled` | 1 | 0 | already proven |

"Floor-freed" is the aggregator's own `floor_nil` predicate (`scripts/bc2cpp_receiver_proof_report.rb:41`): the
column is a number (not `-`, which is a site the floor could not be computed for), `before > 0`, and it reaches 0.
17 of the 91 `block_param` rows are `-`, not 0 — a count that treats `-` as 0 overstates this bucket by exactly those
17.

**`block_param` is 91 of the 173, and it is not an admission-rule failure.** These registers are bound by a *block's*
ENTER, not a method's: `@allies.each { |c| c.actor }` binds `c` from the yield. `entry_arg_candidates` never covered
them — `codegen_fixnum_proof.rb:627-629` says so in as many words ("Not done on purpose: Block parameters: filled by
whatever the callee yields … a different enumeration problem"), and `rp_argument_why` was reporting the enclosing
method's rule for them. That misattribution is what made the bucket look like a parameter-pool problem: `Game::Battle#apply_to_party`
has no parameter at all, yet all ten of its rows were attributed to it, under a rule that described nothing about it.

So the ADR 0331 trigger, taken literally, would have sent the next attempt after method-argument pools for 91 sites
that are block parameters, whose class is a property of the iteration's receiver contents — ADR 0312's mutable-container
element problem, measured and not built in its own right. Of the 91, **21** are floor-freed and 17 more carry no
floor at all (`floor_nil` is `-`, the name is unbounded or answers nothing); the rest keep a by-name line whatever set
is proven. All 21 freed sites have the same one blocker, `accessor:ivar_accessor+ruby_direct`: the receiver is an
attr_reader (`Combatant#actor` most often), so it needs that ivar's class. `Game::Battle#apply_to_party` is **10** of
the 21 — every one of its rows freed — and `actor` is the callee in **17** of the 21.

The genuinely method-shaped buckets are small and each is a different proof, not one lever:

* **`multidef*` (49 sites, 11 floor-freed)** — a POLY name. `ClassArgTypes` skips POLY names for the same reason
  (`class_arg_types.rb:60`): a POLY name's call sites may target different methods, so one position is not one class.
  Proving it needs per-definition call-site sets, which is the same inter-procedural work ADR 0303 declined for the
  computed sends.
* **`arity` (22 sites, 3 floor-freed)** — `pure_mandatory_arity?` refuses a method with optional, rest, keyword or
  `&block` parameters. Widening it changes the generated `_impl`'s `mrb_get_args(M, "oo...")` binding contract, so it
  is a codegen change rather than a proof change.
* **`poisoned`/`dynamic_name`/`outside_token` (11 sites, 1 floor-freed)** — the token over-collection of rules 2/3 and
  ADR 0279's whole-program name universe. Each needs a per-name refinement of a deliberately blunt rule.
* **`dropped` (146 sites, 34 floor-freed)** — ADR 0331's own table, unchanged: a call result (44), another argument
  (40), an element (15) at some call site.

No single bucket clears ADR 0331's 30-send cutoff on its own, and the largest one is blocked by a different ADR.

## Decision

**No receiver proof is built.** The rule split ships (it is the measurement that makes the next attempt aim correctly),
the report's `why` names the rule, and `block_param` is no longer misattributed to the enclosing method.

`block_param` is deliberately **not** given a receiver proof, even though it is the biggest bucket:

* The 91 split 21 freed, 53 with a floor that keeps a by-name line, and 17 with no floor at all (`floor_nil` is `-`).
  A proof of the block parameter's own class reaches only the 21 — the other 70 keep a by-name line whatever set is
  proven, because a block parameter's class is the element class of the iteration receiver, which no existing fact
  provides.
* The 21 that are floor-freed all share one blocker, `accessor:ivar_accessor`: the receiver is an attr_reader, so the
  arm needs that **ivar's** class, not the block parameter's. For 17 of the 21 that ivar is `Combatant#@actor`, whose
  only store is `Combatant#initialize`'s `@actor = actor` — and `actor` is the 11th parameter of a 20-parameter
  `initialize` that is *all* optional (`actor = nil`, battle.rb:237), so `pure_mandatory_arity?` refuses the whole
  method and ADR 0313's constructor pool never reaches it either. Chasing the 21 means three linked pools (block
  parameter → ivar → constructor argument), the first of which is the one ADR 0312 says not to build and the last of
  which is the `arity` bucket above.

21 floor-freed sites is under ADR 0331's 30-send cutoff, and the largest bucket a parameter-pool proof *here* could
serve is `multidef*` at 11. Neither reaches it, and the 91 need ADR 0312 rather than a parameter pool.

Hints are not proofs (ADR 0210, 0290): no guard hint was added for the 91.

## Consequences

* No generated code changes: no kill switch, and `shipped.cxx` is unaffected. The one build measurement is the
  row-count and by-name-total reproduction above.
* The report's `why` column for an argument row is now `no_candidate:<rule>`, `no_candidate:block_param`,
  `no_candidate:native_entry` or `dropped:<kinds>`. `scripts/bc2cpp_receiver_proof_report_check.rb` asserts the rule
  for three distinct rules (3 `outside_token`, 8 `nosites`, and `block_param`) and the block case has a **negative
  control**: with the block-parameter guard disabled, `RpFx#each_block`'s `|c|` is reported
  `no_candidate:nosites` — the misattribution this ADR exists to stop — and the check fails.
* The 91 `block_param` sites are now visible as what they are, so the next attempt does not re-derive ADR 0331's
  trigger and start on method-argument pools for them.
* Not run, because nothing was built: no mutation check beyond the report's own negative control, no
  compiled-versus-interpreted comparison, no withdrawal worlds. The changed Ruby is host-side tooling only; none of it
  is compiled by bc2cpp.

## Triggers to revisit

```sh
MRBC=$PWD/3rd/mruby/build/host/bin/mrbc BC2CPP_RECEIVER_PROOF_REPORT=rp.tsv \
  ruby scripts/bc2cpp_coverage_report.rb > /dev/null
ruby scripts/bc2cpp_receiver_proof_report.rb rp.tsv
```

* **ADR 0312's element classes land.** That is the trigger that moves the largest bucket: the 70 `block_param` sites
  whose floor keeps a by-name line are exactly the sites whose class is the iteration receiver's element class, and
  17 of the 21 freed ones need `@actor`'s class on top of that. `apply_to_party` (10 sites) and the `actor` family
  (17) are the first rows to re-check.
* **A per-definition call-site set for POLY names.** That is the `multidef*` row (49 sites, 11 floor-freed); it is the
  same inter-procedural work ADR 0303 declined for computed sends, and it would serve both.
* **`pure_mandatory_arity?` is widened** (a codegen change to the `_impl` binding contract). That is the `arity` row's
  22 sites, and it is also the third link in the `block_param` chain: `Combatant#initialize` is all-optional, so ADR
  0313's constructor pool cannot see `@actor`'s store until this widens.
* **A per-name refinement of the rule 2/3 token scan or ADR 0279's universe** (`poisoned`, `dynamic_name`,
  `outside_token`: 11 sites, 1 floor-freed) — small, but each is a blunt rule made precise for one name.
