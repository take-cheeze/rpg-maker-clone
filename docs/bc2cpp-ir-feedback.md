# IR type feedback and RBS suggestions

The type-check workflow now connects RBS contracts, bytecode IR facts and
reviewable RBS suggestions. It retains nominal contracts for required
arguments, ivars and method returns, including nullable and union types.
Ivar reads and implicit calls on `self` use the applicable owner/ancestor
contract. An ordinary explicit receiver with known nominal bounds can also use its
return contracts. An unknown receiver does not inherit a return contract
merely because its method name matches; an existing complete compiler proof
can independently establish its result. See [call-result propagation](bc2cpp-ir-call-results.md).

```sh
ruby scripts/bc2cpp/type_check.rb --files game.rb --sig sig/bc2cpp \
  --format json --out coverage/ir-types.json \
  --emit-rbs-suggestions coverage/rbs-suggestions

# Review the candidate files, then check them against the same sources.
ruby scripts/bc2cpp/type_check.rb --files game.rb \
  --sig coverage/rbs-suggestions --all
```

Set `MRBC` to the host compiler path when it is not on PATH. Use an absolute
path when invoking the script from another directory. Candidate files are
written only to the requested output directory; source signature files are
not updated automatically. As with `--emit-rbs`, candidates also retain the
existing parameter, ivar, constant and method inventory. Existing types come
from the standard whole-program facts; independently inferred IR returns
replace return declarations in the candidate copy, including contradicted
ones. This is a review workflow; the default run does not feed its candidates back.

## Fixed-point rounds (`--iterate N`)

A return whose exits are derived through a callee's contract (`derived:contracts`)
is not a suggestion in a single run: the callee's return is only a contract once
it is declared. `--iterate N` closes that loop, opt-in and off by default:

```sh
ruby scripts/bc2cpp/type_check.rb --files game.rb --iterate 5 \
  --emit-rbs-suggestions coverage/rbs-suggestions
```

- Round 1 runs the analysis under `--sig` alone and accepts the returns it can
  infer from bytecode. Round `r` runs again with the round `r-1` accepted set as
  one more signature directory, written to a scratch directory.
- The loop stops when a round accepts exactly what it was given (converged), or
  after `N` rounds (not converged). The report prints the round count and whether
  it converged; with `--emit-rbs-suggestions` the candidates are written only when
  the set converged. A non-converged set is not written, because its derived
  types were computed under contracts from an earlier round.
- Each round's candidates replace the previous ones rather than accumulating:
  a suggestion whose contract was withdrawn cannot survive as a stale contract.
- The candidate directory of a round holds only the accepted methods: parameters
  are untyped, and there are no ivars or constants. Nothing else can become a
  contract in a later round, including a derived type that was not accepted.

**Acceptance rule.** A derived exit is accepted only when every contract it
depends on is a return contract (`self-call:NAME` or `call-result:OWNER#NAME`)
naming a method accepted in the previous round. Parameter, ivar, keyword and
element contracts keep the method out, including those in your own signatures.
That is stricter than the single-run workflow, which only omits the method.
`self-call:NAME` names no owner, so it is accepted only when some previous-round
method has that name and no user declaration does. A method the user already
declares keeps its declaration and is never a suggestion. The rule is enforced in
`accepted_exit?` and `return_contract_accepted?` in `tools/bc2cpp/type_check_iterate.rb`.

**Cycles.** Round 1 has no candidates, so a derived exit cannot exist there and
only inferred returns are accepted. Every later round is built from the previous
one, so each accepted return traces back to an inferred exit or a user contract.
Two methods whose returns depend only on each other (A on B, B on A) are never
accepted from nothing; the loop converges in one round with neither. The loop stops
only when a round reproduces its own input.

Not verified here: the end-to-end run needs the host `mrbc`. The loop and its rule
are exercised by `scripts/bc2cpp/type_check_iterate_check.rb` against a model of the
analysis, not the real one.

## Feedback

JSON includes `ir_feedback` rows for method exits, ivar stores and explicit
call receivers. Each row records its source location, type, expected contract,
contract provenance and refusal reason. Statuses distinguish:

| Status | Meaning |
| --- | --- |
| `inferred` | The IR answer needs no RBS assumption |
| `declared` | The answer depends on argument, ivar or self-call contracts |
| `unknown` | No complete answer; `reason` names the unknown producer or dataflow refusal |
| `mismatch` | Every class in the inferred may-set falls outside the nominal contract |
| `possible_mismatch` | The may-set contains both allowed and excluded classes; feasibility/refinement is unresolved |

Text output summarizes statuses and unknown reasons and lists inferred return
suggestions. `--all` adds location-based unknown-query notes (`TC2004`).
Wholly incompatible inferred returns or ivar stores produce errors (`TC1007`);
partly overlapping sets produce warnings (`TC1008`). Subtype compatibility
uses the program hierarchy, recorded mixins and the primitive classes' core
ancestry. Missing module or external-type relations leave `compatibility`
unknown instead of creating a mismatch. These
checks are static feedback; they do not add runtime enforcement.

JSON's `rbs_suggestions` lists return types only when every modeled exit has
an independently inferred answer. Contract-assisted or unknown exits cannot
produce an independent suggestion. New union-return facts also improve normal
`--emit-rbs` output when the existing return analysis has no answer.

Complete contract-assisted return bounds appear with source `derived:contracts`
and retain their dependency list. They are not independent RBS suggestions.

## Boundaries

Facts remain nominal when declared; they cannot prove exact dispatch or
native representation. Inference may over-approximate infeasible paths, so
mixed sets are warnings rather than definite errors. Handler and closure
barriers, frame clobbers and traversal budgets still refuse queries.

Shared IREPs with ambiguous owners get no owner-specific contracts. Cyclic
hierarchies supply no inherited contracts. Optional/rest/keyword/block
contracts, unknown receiver contract lookup, module mixin contract lookup, constants
and nonlocal-return inference remain follow-up work. Inferred ivar types
continue to come from the existing whole-program layout analysis; observing
one store does not establish the complete type of an ivar.

Run the signature, type-check and RBS-export checks with a host `MRBC`. The
fixture suites compare guarded dispatch with `BC2CPP_STRICT_HINTS=0`.
See [ADR 0442](adr/0442-bc2cpp-ir-contract-feedback.md).
