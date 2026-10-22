# Decided-branch folds on parameters: which refusals a proof could lift

Analysis only. The guard in `tools/bc2cpp/codegen_decided_branch.rb` (`defs.any?(&:entry?)`) is unchanged.

## What the guard refuses

A conditional jump whose tested register may still hold an argument is not folded. The flow cannot see every caller of a
method installed by `define_method`, so an argument can be nil with no caller in view (the `dl_b(nil)` miscompile).

## What already proves an argument's mask

`codegen_numeric_args.rb` (ADR 0276) gives an argument register the join of the masks at every call site, but only for a
candidate admitted by `entry_arg_candidates` (`codegen_fixnum_proof.rb`). A candidate needs: one definition, not a foreign
or outside-named method, not poisoned, not dynamically named, pure mandatory arity, at least one call site, and every site
passing the mandatory arity. A non-candidate's argument has mask `OTHER`.

## Measurement

Probe: `CodeGen#decided_branch_outcome` wrapped in scratch to record each refusal with `defs.any?(&:entry?)` true and the
tested register's mask. Run on the two fixtures in `scripts/bc2cpp/`.

| Fixture | Distinct refused sites | Mask | Pooled proof |
|---|---|---|---|
| `decided_branch_check.rb` | 2 (JMPNOT, reg 7) | OTHER (64) | none |
| `define_method_check.rb` (`DmLoop`) | 3 (JMPNIL, JMPNOT) | OTHER (64) | none |

Classification, with the facts available today:

- provable with an existing fact: 0
- unprovable (no proof, mask `OTHER`): 5
- unknown (engine not measured): not counted

The engine count was not measured. A closed-world generation with the probe loaded is the next step; the closed-world
tree from the engine-count investigation exists in another worktree and was not reused here.

## The unlocking fact

The only fact that could lift these refusals is the candidate proof above: the method is a candidate and its pooled
argument mask is not `OTHER`. Relaxing the guard to "pooled mask is a proof" would be sound under ADR 0276. It would not
lift these five sites, since their pooled mask is `OTHER`.

## A soundness question found on the way (not part of this analysis)

`decided_branch_outcome` folds `JMPNIL` as not taken whenever the mask has no NIL bit:
`return :not_taken if (mask & NumericFlow::NIL).zero?`. `OTHER` has no NIL bit, but `OTHER` is the unknown value and can be
nil. So a `JMPNIL` on an `OTHER` register would fold to not taken unsoundly. The fixtures do not exercise this: all their
`JMPNIL` folds have a NIL-only mask. Whether the engine's not-taken `JMPNIL` folds include `OTHER` masks was not measured.
The conservative rule would be `(mask & (NIL | OTHER)).zero?`. That is a separate change for the owner of the fold.
