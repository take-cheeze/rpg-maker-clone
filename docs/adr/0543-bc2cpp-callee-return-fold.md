# 0543. bc2cpp: decide a jump on a call that always returns a literal

Date: 2026-10-22

## Status

Accepted. Off by default: it is on only with `BC2CPP_RETURN_FOLD=1`. With the gate off the generated C++ is unchanged.

## Context

The decided-branch folds (ADR 0532) decide a jump from the NumericFlow class mask of its register. A call result takes
its mask from the return-class facts. Those masks have no bit for `true` or `false`: TrueClass and FalseClass are OTHER,
which may be nil or false. So a predicate whose every return is a literal, such as `def ok?; true; end`, leaves
`if ok?` as a runtime `mrb_test`, even though the program fixes the outcome.

## Decision

`CodeGen#callee_return_outcome` (tools/bc2cpp/codegen_callee_return_fold.rb) is consulted by `decided_branch_outcome`
after the mask decision. It decides a `JMPIF`, `JMPNOT` or `JMPNIL` whose register's every reaching write is a
`SEND`, `SEND0`, `SSEND` or `SSEND0` result, when every definition of each called name returns only literals:

- the name is fully visible to the closed world, not foreign, not aliased, not installed by a symbol and not reached by a
  computed-name send (the admission the Fixnum return proof uses);
- every definition is a bytecode body with no catch handler and no non-local exit;
- every return source is `LOADTRUE`, `LOADFALSE`, `LOADNIL`, or a nil fall-through.

The literal kinds form a set over `{true, false, nil}`. `JMPNIL` is taken only when the set is `{nil}`, and never when
`nil` is absent. A truthy set (`{true}`) decides `JMPIF` taken and `JMPNOT` not taken, and a falsy set (`{false, nil}`)
decides the opposite. A mixed set is kept.

A `SENDB` result is never read: a `break` supplies its value. A call that raises yields no value and takes no edge.

Because the outcome comes from `decided_branch_outcome`, the emitter and the arm pruner (codegen_arm_prune.rb) make the same
decision.

## Consequences

- Off by default. With the gate unset, the generated code for every method of the mruby-rpg2k mrblib sources is
  byte-identical to the generator before this change (one codegen run per tree, compared with `cmp`).
- The fixture `scripts/bc2cpp/callee_return_fold_check.rb` checks the folds with the gate on and off, and the refusals:
  a define_method, a computed-name send, an alias, a method_missing owner, a return inside a block, a rescue handler and
  a block call.
- Soundness rests on the registry listing every body a name can run, the same assumption the Fixnum and class return
  proofs make.
- Engine count: not measured. The closed-world build (`scripts/bc2cpp/closed_build.bash`) needs third-party submodules
  this worktree does not provide (quickjs, uni_algo, stb, lvgl), so the gate-on and gate-off trees could not both be
  generated. The partial codegen run, which lacks the closed world's foreign-name table, folds nothing, so it says
  nothing about the engine.
- Not folded: `is_a?` on a result whose class the mask already knows. The class-test narrowing does not decide
  `is_a?(String)` on a String-masked value (a local or a call result alike), so that is a separate gap.
