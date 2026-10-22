# Block-body decided-branch folds: isolation measurement

Measures how many decided-branch folds (ADR 0532) the block-body change in
commit 984084a3 ("bc2cpp: decide block-body jumps from the block's own state")
adds to the closed-world build, and whether the removed `mrb_test(` and
`mrb_nil_p(` calls match.

## Builds

| Build | Commit | Notes |
|---|---|---|
| baseline | 7864e134 (parent of 984084a3) | block-body folds refused (passes `offset`) |
| fold | 984084a3 | block-body folds enabled (passes `0`) |

Both use the default gate `BC2CPP_DECIDED_BRANCH` (unset, so on).

Generator flag: `bc2cpp.rb` has no way to pass `--annotated` through the rake
build. For this measurement only, `tools/bc2cpp/bc2cpp.rb` line 176 was set to
`annotated = true` (uncommitted, equivalent to `--annotated`) so the generated
C++ keeps its `DECIDED_BRANCH` markers. Nothing else in the source was changed.

Submodules initialised (shallow) in each worktree: `3rd/mruby`,
`3rd/mruby-marshal`, `3rd/mruby-onig-regexp`, `3rd/mruby-stringio`,
`3rd/mgem-list`, `3rd/stb`, `3rd/ng-log`, `3rd/inicpp`, `3rd/uni-algo`,
`3rd/lvgl`, `3rd/quickjs`.

## Commands

```sh
git worktree add --detach <scratch>/wt-base 7864e134
git worktree add --detach <scratch>/wt-fold 984084a3
# in each worktree
git submodule update --init --depth 1 3rd/mruby 3rd/mruby-marshal 3rd/mruby-onig-regexp \
  3rd/mruby-stringio 3rd/mgem-list 3rd/stb 3rd/ng-log 3rd/inicpp 3rd/uni-algo 3rd/lvgl 3rd/quickjs
# build (g++ compile included)
scripts/bc2cpp/closed_build.bash <scratch>/build-base   # in wt-base
scripts/bc2cpp/closed_build.bash <scratch>/build-fold   # in wt-fold
# count
ruby scripts/bc2cpp/decided_fold_count.rb <scratch>/build-base/closed/mrbgems
ruby scripts/bc2cpp/decided_fold_count.rb <scratch>/build-fold/closed/mrbgems
```

## Results

Both builds completed: `closed/lib/libmruby.a` was written in each, so the g++
compile of the generated closed-world C++ succeeded.

Marker counts (`decided_fold_count.rb`, one directory each):

| Build | Markers | JMPIF taken | JMPNIL not taken | `mrb_test(` | `mrb_nil_p(` |
|---|---|---|---|---|---|
| baseline 7864e134 | 18 | 17 | 1 | 1780 | 310 |
| fold 984084a3 | 18 | 17 | 1 | 1780 | 310 |

Difference: 0 folds and 0 call drops.

Generated C++ check: after replacing the two build directory names and the
two worktree names, `rpg2k_compiled_gen.cpp`, `lcf_compiled_gen.cpp`,
`rgss_compiled_gen.cpp` and `core_compiled_gen.cpp` are identical between the
two builds (0 differing lines each).

## Interpretation

- The 18 folds are present in the baseline too, so they are top-level folds,
  not block-body folds. The block-body change adds none in this closed world.
- The two-directory form of `decided_fold_count.rb` reports DISAGREE here
  (folds 18, drops 0). That is an artefact of the comparison, not a mismatch:
  the script expects its second directory to be a folds-off build
  (`BC2CPP_DECIDED_BRANCH=0`), and the baseline here is the parent with
  top-level folds still on. A folds-off comparison was not run.
- Conclusion: in the closed world, the block-body change is a no-op. Its
  expected fixture (literal-array `each` block) is not in the closed world's
  compiled code, or no block-local nil test there meets the decision rule.
