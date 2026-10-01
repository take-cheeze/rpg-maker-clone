# 0300. CI runs the width-sensitive bc2cpp checks on 32-bit and no-bigint builds, and listens for the merge queue

Date: 2026-10-01

## Status

Accepted

## Context

Two gaps let a red build reach `master`.

- **Width.** The Emscripten, Wio and PSP targets build mruby with a 32-bit `mrb_int` (31-bit Fixnums
  with `-DMRB_32BIT`), and the Wio and PSP builds carry no mruby-bigint. Every CI job builds the 64-bit
  host. ADRs 0279, 0287 and 0292 wrote the 32-bit and no-bigint legs into their checks, but only behind
  `BC2CPP_MRUBY_FULL32` / `BC2CPP_MRBC32` / `BC2CPP_MRUBY_NOBIGINT`, which no job set, so those legs
  skipped everywhere but a developer's machine (AGENTS.md records the same for the `mrb_int` traps).
- **Interaction.** `build.yml` ran on `pull_request` and `push` to `master`, so a PR was tested against
  the `master` it branched from. Two PRs each green on their own turned `master` red once both merged.

## Decision

- A new `bc2cpp-width` matrix job (`int32`, `nobigint`) builds one extra full-core libmruby with
  `scripts/bc2cpp_width_build.rb` and runs the checks whose 32-bit / no-bigint legs already exist:
  `int32` runs `bc2cpp_numeric_slow_check`, `bc2cpp_fixnum_overflow_check`, `bc2cpp_step_inline_check`
  and `bc2cpp_lcf_row_flow_check`; `nobigint` runs
  `bc2cpp_numeric_slow_check`. The `int32` build is the 64-bit host with the targets' defines (their
  arithmetic, not their pointer width), the same stand-in the checks documented. The `bc2cpp`
  aggregate now also needs `bc2cpp-width`, so the existing required status keeps gating on everything.
- `bc2cpp_lcf_row_flow_check` gained the 32-bit leg (it ran at 64 bits only).
- `bc2cpp_unlisted_class_call_check` has a 32-bit leg too but is left out: its generated-code section
  fails at 64 bits on master (the `core-mrbtest` shard reports the same 17 failures), so it says
  nothing about width. Add it to the `int32` list once that is fixed.
- Reusing the shard layout, the job builds only the bootstrap host mrbc with cmake (which also applies
  the mruby patch chain), then the width libmruby with rake; no sccache for the rake build.
- `build.yml` also triggers on `merge_group` (`checks_requested`). No job needs a change: the
  `issue_comment`-only jobs stay off, and the deploy jobs already require `push` to `master`.
  `docs/ci.md` lists the repository settings the owner has to turn on; nothing in the repository can.

## Consequences

- A 32-bit-only or no-bigint-only regression in the covered checks fails the PR instead of the deployed
  page. Checks without a width leg (bc2cpp_guard_violation, bc2cpp_numeric_operand, ...) and real
  32-bit pointer width (gcc -m32 / an Emscripten build of the checks) remain uncovered.
- Cost: two more jobs, roughly a full-core mruby build (a few minutes) plus the checks each;
  `bc2cpp_step_inline_check` also builds a 64-bit full-core mruby of its own.
- Without a merge queue (or "require branches to be up to date") the interaction gap stays open; the
  trigger alone changes nothing until the owner enables the setting.
- ADRs 0279, 0287 and 0292 say CI does not run the 32-bit or no-bigint legs; this ADR supersedes
  that sentence for the checks listed above.
