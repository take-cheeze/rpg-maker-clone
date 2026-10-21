# Decided-branch refusals on parameters, counted on the engine

ADR 0532 folds a conditional jump whose tested register the NumericFlow state decides. The entry-definition guard in
`tools/bc2cpp/codegen_decided_branch.rb` refuses every such fold when a reaching definition is a parameter, because a
`define_method` body can be called with values the flow does not see. This note counts how many decisions that guard
refuses on the real engine, and how many of them the pooled entry-argument mask (`numeric_entry_mask`, the ADR 0276
candidate fact) would prove.

## Method

- The closed-world build of the engine (`MRUBY_TARGET=closed RPGMAKER_BC2CPP=1 BC2CPP_HOT_ONLY=0`) was run on a scratch
  copy of the tree with master's `tools/` in place and an instrumented `codegen_decided_branch.rb`. The instrumentation
  is not committed; it only records, at each guard refusal, the tested mask and the pooled mask.
- For each refused decision the census records:
  - `known`: every reaching entry definition has a pooled mask that is positive and not OTHER;
  - `pooled`: `known` and the pooled mask (ANDed with the tested mask, minus OTHER) decides the jump;
  - `tested`: the tested register's own mask decides the jump (the guard is the only thing holding the fold back).
- Each compile process writes its own census file. Sites are merged by key (owner, method, irep, index, op). A site
  counts as a proof only when every process that refused it agrees.
- The build finished with exit status 0, and the census was written by four processes.

## Engine result

| JMP op  | Refused sites | (a) pooled mask proves | (b) pooled mask OTHER, zero or missing | tested mask alone decides |
|---------|--------------:|-----------------------:|---------------------------------------:|--------------------------:|
| JMPIF   | 189 | 0 | 189 | 3 |
| JMPNOT  | 256 | 0 | 256 | 4 |
| JMPNIL  | 41  | 0 | 41  | 1 |
| **Total** | **486** | **0** | **486** | **8** |

- No refused decision is proved by the pooled entry-argument mask.
- Every refused site has an entry definition whose pooled mask is OTHER, zero or missing in at least one process.
- Eight refused sites would be decided by the tested mask alone. These are the only refusals the guard costs that the
  flow could decide without the parameter's pooled mask.
- 39 site keys were seen in more than one process with different flags. The disagreement is in the pooled `known` and
  `pooled` flags only (the site itself is the same). Each such site was counted (b) because at least one process saw
  OTHER, zero or missing. Each process only sees the callers compiled in it, so the pooled masks differ by process.

## Fixture cross-check

The same instrumentation run on the two fixture checks reproduces the fixture totals:

- `scripts/bc2cpp/decided_branch_check.rb` refuses 2 decisions (both `JMPNOT`, in the `Router#route` fixture).
- `scripts/bc2cpp/define_method_check.rb` refuses 3 decisions (all `JMPNIL`, in the `DmLoop` fixture).

Both are (b): the pooled mask is OTHER or missing. The fixtures agree with the engine on the classification.

## What this means

- On the engine, the ADR 0276 pooled mask would not unlock any refused decision in the measured build. Pooling
  parameter masks is not a route to more folds on these sites.
- The guard's cost on the engine is at most 8 tested-mask decisions (3 JMPIF, 4 JMPNOT, 1 JMPNIL). Those are the
  candidates for any follow-up, and each would need its own soundness argument before the guard is loosened.
- The 39 per-process disagreements mean a pooled mask is only as complete as the callers its process compiled. Any
  future use of the pooled mask as a proof needs the mask built over the whole closed world, not per process.

## Reproducing

The census instrumentation is scratch-only. The counts above come from a closed-world annotated build (`--annotated`,
so the `DECIDED_BRANCH` markers survive) with the instrumented guard, aggregated by merging the per-process files by
site key.
