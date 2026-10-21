# Block-body decided-branch folds: verification

Candidate 1 changes `tools/bc2cpp/codegen_loop_regions.rb` so block-body jumps
ask `decided_branch_outcome` with the block's own offset (0) rather than the
owner's offset. This note records what was checked on the full closed-world
engine build. The fold rules themselves are in ADR 0532.

## What was run

- Tree: `984084a3` (candidate 1 cherry-picked onto `origin/master` `7864e134`),
  with the TEMP-only comment-keeping edit to `tools/bc2cpp/bc2cpp.rb` reverted
  before this commit.
- Gate on: `scripts/bc2cpp/closed_build.bash` with `BC2CPP_HOT_ONLY=0`,
  output in `build-on/`.
- Gate off: same script, same tree, `BC2CPP_DECIDED_BRANCH=0`, output in
  `build-off/`.
- Both builds were run with `--annotated` output so `DECIDED_BRANCH` markers
  survive (the default `CompactOutput` strips `//` comments, ADR 0463).
- Count: `ruby scripts/bc2cpp/decided_fold_count.rb build-on/closed build-off/closed`.

## Results

| | gate on | gate off |
|---|---|---|
| Closed-world build | exit 0, `libmruby.a` and `shinonome.hxx` written | exit 0 |
| Generated C++ compiled with g++ | yes (part of the build above) | yes |
| `DECIDED_BRANCH` markers | 58 | 0 |
| markers by kind | JMPIF taken 44, JMPNOT taken 1, JMPNOT not taken 10, JMPNIL not taken 3 | — |
| `mrb_test(` calls | 9422 | 9477 |
| `mrb_nil_p(` calls | 1322 | 1325 |

Drops with the gate on:

- `mrb_test(` dropped by 55, equal to the 55 JMPIF/JMPNOT folds
  (44 + 1 + 10). Each fold removes exactly one `mrb_test(`.
- `mrb_nil_p(` dropped by 3, equal to the 3 JMPNIL not-taken folds.
  Each fold removes exactly one `mrb_nil_p(`.

The counter reports: "agree: every fold removes exactly the test it replaces".

## Not established

- **The block-body share is not isolated.** Both builds include candidate 1, so
  the 58 folds are all decided-branch folds in the tree, not only the block-body
  ones. A block-body-only count needs a build of `master` as the baseline.
- **No behavioural check was run.** No executed differential harness covered
  the block-body folds, so runtime equivalence is established only by the
  interpreter-level reasoning in the candidate-1 change and by the count match
  above.
- The earlier JMPNIL not-taken count of 75 came from the pre-#2545 tree, where the
  not-taken rule was unsound for OTHER masks. The current tree gives 3 such folds.
