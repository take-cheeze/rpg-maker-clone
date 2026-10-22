# Parameter-fold gate on the engine closed world: measurement

Measurement of the `BC2CPP_PARAM_FOLD=1` completeness gate (ADR 0540, PR #2563) on the engine closed world. The gate
stays off by default; this page records what it changes.

Base: `origin/master` at `81709076`, with submodules initialised (`3rd/mruby` and the gems the closed build reads).
Builds used the scratchpad, not the repository.

## Commands

```sh
# 1. Gate off, full closed-world build (rake + g++ compile).
unset BC2CPP_PARAM_FOLD
scripts/bc2cpp/closed_build.bash "$S/build-off"

# 2. Gate on, same build.
export BC2CPP_PARAM_FOLD=1
scripts/bc2cpp/closed_build.bash "$S/build-on"
unset BC2CPP_PARAM_FOLD

# 3. Annotated whole-program generation (DECIDED_BRANCH markers kept), kept shipped.cxx.
MRBC="$S/build-off/host/mrbc/bin/mrbc" BC2CPP_COVERAGE_KEEP_DIR="$S/annot-off" \
  ruby scripts/bc2cpp/coverage_report.rb          # gate unset
MRBC="$S/build-off/host/mrbc/bin/mrbc" BC2CPP_COVERAGE_KEEP_DIR="$S/annot-on" \
  ruby scripts/bc2cpp/coverage_report.rb          # BC2CPP_PARAM_FOLD=1 exported

# 4. Determinism of the gate-off output: generate once more and compare.
MRBC=... BC2CPP_COVERAGE_KEEP_DIR="$S/annot-off2" ruby scripts/bc2cpp/coverage_report.rb
cmp "$S/annot-off/shipped.cxx" "$S/annot-off2/shipped.cxx"

# 5. Fold counts and test-call drops.
ruby scripts/bc2cpp/decided_fold_count.rb "$S/annot-on" "$S/annot-off"
```

`$S` is the session scratchpad. `coverage_report.rb` runs `bc2cpp.rb --annotated` over the closed world with
`SKIP_UNSUPPORTED=1` (the shipped pass) and keeps its output. It exits non-zero after writing the file, because its
`INTEGER_CONSTANT_PROOF` section lookup does not match this run's diagnostic. The kept `shipped.cxx` is complete.

## Results

| Measure | Gate off | Gate on | Delta |
| --- | --- | --- | --- |
| DECIDED_BRANCH markers (total) | 58 | 64 | +6 |
| JMPIF taken | 44 | 46 | +2 |
| JMPNIL not taken | 3 | 4 | +1 |
| JMPNOT not taken | 10 | 13 | +3 |
| JMPNOT taken | 1 | 1 | 0 |
| `mrb_test(` calls | 9415 | 9410 | -5 |
| `mrb_nil_p(` calls | 1284 | 1283 | -1 |

- The six added folds are exactly the gate's: five remove an `mrb_test(` (JMPIF and JMPNOT) and one removes an
  `mrb_nil_p(` (JMPNIL). The drops equal the added folds, kind by kind.
- `decided_fold_count.rb annot-on annot-off` prints `DISAGREE` and exits 1. Its comparison uses every gate-on fold
  (64) against the drop (6 expected by the delta). The 58 folds in gate-off are ADR 0532 folds that the gate does not
  touch. The script assumes the off tree carries no folds, so the delta is the correct comparison, and it agrees.
- Gate-off determinism: `annot-off` and `annot-off2` are byte-identical (`cmp` exit 0).
- The gate-off build is `origin/master` itself, so this is the master build. There is no separate pre-PR build.

## Real closed-world build (rake)

- Gate off: `closed_build.bash` exits 0, `libmruby.a` built, no `error:` lines in the g++ output.
- Gate on: `closed_build.bash` exits 0, `libmruby.a` built, no `error:` lines. The gate-on build compiles with g++.
- The rake-generated compact `*_compiled_gen.cpp` files (core, lcf, rgss, rpg2k) differ between the two builds only in
  the build-directory path in their `#include` lines. After normalising the path, they are identical. The gate added no
  change to the per-gem output of the real build.
- Hypothesis, not verified: the per-gem rake runs pass a partial `ONLY_OWNERS`, so the gate's "closed world is whole"
  condition (`codegen_param_fold.rb`) fails there. The whole-program diagnostic run has all owners and sees the six
  folds. Checking this needs the gate's `@closed_world` in a per-gem run.

## Open items

- The six folds appear only in the whole-program annotated run, not in the per-gem rake output. Until the whole-world
  condition is confirmed, the real build does not show the gate's effect.
- Turning the gate on by default needs the rake-level difference to be understood first, as ADR 0540 says.
