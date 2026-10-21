# Not-taken JMPNIL folds by NumericFlow mask (pre-#2545 engine)

Measurement report for the decided-branch fold rule in `tools/bc2cpp/codegen_decided_branch.rb` (ADR 0532).
Before #2545, a JMPNIL was folded to "not taken" when `(mask & NIL).zero?`, which also folded masks that
carry `OTHER` (an unknown value that may be nil). #2545 changed the test to `(mask & (NIL | OTHER)).zero?`.

This report counts how many of the not-taken JMPNIL folds of the pre-fix engine had `OTHER` set, and how
many had neither bit. Only the neither-bit folds survive #2545; the `OTHER` folds are the ones it removes.

## Result

| Class | Folds | Meaning |
| --- | --- | --- |
| Total not-taken JMPNIL markers (rpg2k closed-world output) | 75 | `DECIDED_BRANCH JMPNIL R<n>: not taken` |
| Mask had `OTHER` (64) set | 72 | folded wrongly before #2545; undecided after it |
| Mask had neither `NIL` nor `OTHER` (mask 1) | 3 | still folded after #2545 |

Cross-check: `ruby scripts/bc2cpp/decided_fold_count.rb <mruby-rpg2k-compiled dir>` on the same output reports
`JMPNIL not taken: 75`, equal to the marker grep. The 75 matches on both counts.

The 3 neither-bit folds, all in `Game::Interpreter`:

- `Game::Interpreter#map_event_call` (one of its two folds; the other is `OTHER`)
- `Game::Interpreter#event_operand`
- `Game::Interpreter#character_facing`

## How the counts were taken

1. The pre-fix rule was instrumented in a scratch copy of `codegen_decided_branch.rb`. It logged the mask, owner,
   method name, irep label and instruction index only when a not-taken JMPNIL was actually emitted (the
   `decided_branch_code` path), not when the outcome was merely evaluated. Evaluation also happens in the
   arm-pruning analysis and in fixed-point passes, so logging at evaluation over-counts.
2. The rpg2k closed-world output was regenerated with that copy (`BC2CPP_HOT_ONLY=0`, `--annotated` markers).
3. Each marker was attributed to its emitted site. A marker belongs to the method whose header precedes it,
   except that block bodies (`*_block_fallback_N_impl`) sit under the header of the method that happens to be
   printed before them. Two such block sites were resolved by their function name:
   - a `Game::State.singleton#from_lsd` block (irep 85897, instruction 29), `OTHER`, which sits under the
     `Game::State#se_chunk` header;
   - a `kana_step_col` block (irep 284483, instruction 10), `OTHER`, which sits under the
     `RPG2k::Scene::Map#name_kana_rows` header.
4. Where a site was logged in several passes with different masks (`Game::Interpreter` sites), the last
   emission in the log is the one that reaches the output.

Per-method matching of the logged sites to the markers agrees for every method in the output: 73 markers match
logged sites one for one, and the two block sites above account for the remaining 2.

## Caveats

- The log also holds sites from other closed-world methods (`RGSS`, `LCF`, core `Range`, `Hash`, `Struct`,
  and others). None of them is in the rpg2k output, so they are excluded from the 75.
- Affected method names are listed above only for the `NEITHER` case. The `OTHER` cases (72) are too many
  to list here; rerun the instrumented generator to reproduce them.
- The scratch instrumentation is not committed. Only this report is.
