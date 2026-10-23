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
ones. This is a review workflow, not an automatic fixed-point rewrite.

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
partly overlapping sets produce warnings (`TC1008`), unless trace evidence
applies (below). Subtype compatibility
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

### Trace evidence

`type_check.rb --trace CANDIDATES.rbs` takes the candidates that
`scripts/bc2cpp/trace_types.rb candidates` writes from `BC2CPP_TRACE_TYPES`
dumps. A `possible_mismatch` return row whose method the trace observed only
inside the contract is reported as `TC1009` (info), not `TC1008` (warning). The
row gets `provenance: "trace"` and `trace_classes`, and its status stays
`possible_mismatch`: a trace run is evidence from one run, not proof, so it
never becomes `inferred` or `declared`.

The join is by method (owner and instance method name). The trace records no
file or line for a return, and the candidates leave out overflowed sites and
untyped, interface or generic returns, so only a complete observation counts.
Nil and bool in the candidates count as NilClass and TrueClass plus FalseClass;
an expectation must name every such class. `mismatch` rows, ivar stores, block
rows and singleton methods are never changed by trace evidence, so a class the
static analysis excludes still raises `TC1007`. The implementation is
`tools/bc2cpp/ir_trace_evidence.rb`; `scripts/bc2cpp/ir_trace_evidence_check.rb`
is the host-only fixture check.

## Boundaries

Facts remain nominal when declared; they cannot prove exact dispatch or
native representation. Inference may over-approximate infeasible paths, so
mixed sets are warnings rather than definite errors, and trace evidence only
lowers them to notes. Path-sensitive narrowing is not applied to these rows:
`NilNarrowing` feeds the parameter checks, not the IR type query. Handler and closure
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
