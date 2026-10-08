# 0377. bc2cpp: admit a change by soundness and size, not a site-count cutoff

Date: 2026-10-08

## Status

Accepted. It replaces the cutoff for building that ADR 0317, 0325, 0326, 0331 and 0318 gave as "at least 30 removed
by-name sends". Those ADRs keep their measurements; only the admission rule changes.

## Context

From ADR 0317 on, each bc2cpp change was built only if it removed at least 30 by-name sends in the engine gems. The
rule kept the compiler from growing a proof for every small population. It also measured a change by one number, the
sites it removes, which says nothing about how hard the change is to get right.

The population the cutoff was guarding against has narrowed. Measured on master, the remaining by-name sends fall into
groups where each proof is sound but small, or where the count is well under 30:

- Constants: a scope-qualified rule over literal or single-class definitions admits on the order of a hundred
  sites. The superclass gap is closed; core collisions are still open.
- Element containers: 168 sites, but only 4 have every writer classed. The rest need a whole-program container proof.
- Native exposure: 1 to 3 sites under the audited native class results.
- Join arms: 92 ambiguous joins, and none of the blocking arms is provable by a join rule alone.
- Call results and accessor returns: the blocking groups need chained return facts, not a single rule.
- Alias keying: a per-owner withdrawal is unsound, because return facts are keyed by name. The shipped build gains 0.

Under the count gate, a sound rule with a small footprint is dropped whenever its site count is under 30, even when it
costs one codegen hook and one check.

## Decision

A bc2cpp change is built when it meets both conditions. The site count is reported, but it is not a gate.

1. **Sound, with a check.** The change states its soundness condition in one place, and a check exercises the rule
   including its failure cases (the refused forms, not only the admitted ones). A rule that cannot state its condition
   is not built, whatever its count.
2. **Small.** The codegen footprint is one rule that reuses an existing gate (for example the exact-class arm, the
   nil-or-K receiver path, or the class pools). A rule that needs a new runtime helper, a new proof pass, or a new
   escape analysis needs its own ADR and a measured size argument before it is built.

Every change still reports its effect on the shipped C++: the generated functions that change, and the by-name sends
removed or added, from a kill switch off against on, on one tree. A change whose generated C++ changes is reported before
it is merged. A change that alters no generated C++ is merged on its checks.

## Consequences

- Smaller rules become buildable, so the compiler can accumulate many narrow proofs. Each one adds maintenance, so a
  rule that no longer applies must be removed rather than left behind; the kill-switch audit is the place to check this.
- The count stops being a reason to skip a sound rule. It is still the first question in every measurement, so a rule
  that removes one or two sites needs a stronger argument for its footprint.
- The earlier cutoff ADRs keep their numbers and measurements. Their "cutoff" sentences now point here.
- Constants, native exposure and the join arms are reconsidered under this rule. None of them is built by this ADR; each
  still needs its own soundness argument.
