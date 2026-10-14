# 0442. IR contract feedback and reviewable RBS suggestions

Date: 2026-10-14

## Status

Accepted

## Context

Required-argument contracts alone leave ivar reads and call results unknown.
Users also need an observable feedback loop: see how contracts propagate,
find incompatible values, and export independently inferred types for review.
A reaching-definition type set is an over-approximation, so one excluded
member does not prove that the corresponding path is feasible.

## Decision

Retain matched RBS ivar and return contracts separately from optimization
hints. Bind them to unique IREP owners, resolve ancestor contracts through
the program hierarchy, and seed ivar reads and implicit self-call results.
Keep arbitrary receiver calls unknown. Add contract provenance to immutable
IR facts and preserve inference-only queries and all existing refusals.

Collect feedback during type-facts reporting for returns, ivar stores and
explicit call receivers. Report independent inference, contract dependence,
unknown causes and compatibility with nominal return/ivar bounds. A wholly
disjoint inferred may-set is an error; a partly overlapping one is a warning.
Declared bounds do not themselves establish a contradiction. Respect known
class and mixin relationships; unresolved external or module relationships
remain unknown instead of proving disjointness.

Use complete, independently inferred exit sets as return suggestions. Add
`--emit-rbs-suggestions DIR`, reusing the standard RBS exporter but replacing
return types in a candidate copy. Do not update authored files. Retain the
existing whole-program inference for ivar suggestions; one observed store
cannot prove the complete ivar type. Expose feedback and suggestions in JSON
and text, and add inferred union returns to otherwise untyped return facts.

## Consequences

Users can inspect provenance and refusal causes, review candidate RBS, and
read it back through the same checker. Regression fixtures cover the round
trip, inherited fields, self-call summaries, dynamic-call refusal and partial
versus disjoint mismatches. Generated dispatch and runtime enforcement are
unchanged. Reporting has additional analysis cost only when type facts are
requested. Candidates remain reviewable suggestions rather than an automatic
fixed-point update, particularly when existing contracts depend on each other.
