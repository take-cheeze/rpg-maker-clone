# 194. Deleting the checked-in `def` for a genuinely dead method

Date: 2026-09-22

## Status

Accepted

## Context

docs/adr/0193 turned bc2cpp.rb's "never called" diagnostic into a real
mechanism, but a deliberately conservative one: it only stops registering
an AOT-compiled C++ override, leaving the method's own interpreted
bytecode `def` untouched as a safety net. That net is what makes the
mechanism safe even against a static-analysis miss -- if some call site the
scan cannot see does exist, the method still works, just interpreted.

A natural next question: since "never called" (bc2cpp.rb's own reachability
scan, over `closed_world_mrblib_srcs` + `NATIVE_SRCS`) does not depend on
`RPGMAKER_BC2CPP` at all, could a genuinely dead method's `def` just be
deleted outright, everywhere, benefiting every build target's flash and
interpreter dispatch cost, not only wio's AOT path?

Investigating this surfaced a real, load-bearing gap: **bc2cpp.rb's own
reachability scan has no visibility into anything outside the engine's own
mrblib and native sources.** It does not read `test/`, `scripts/`, or
anything else -- by design, since that scope is exactly right for its own
decision (whether an AOT override is worth registering; a missed call site
elsewhere still works fine, interpreted). It is the *wrong* scope for
deciding whether a `def` is safe to delete outright, because deleting it
removes the method's only remaining implementation for every caller,
including ones the AOT-registration decision never needed to see.

This was not a hypothetical near-miss: `LCF::Database#maker` and
`Game::Character#front_tile` both showed up in bc2cpp.rb's own "never
called" list with identical evidence. A repo-wide search (not scoped to
`closed_world_mrblib_srcs`) shows `#maker` is called from
`mruby-lcf/test/lcf_test.rb` (a real mrbtest assertion), and from
`scripts/lcf_testbed_check.rb`/`scripts/rpg2k3_battle_command_check.rb`
(host-side CRuby check harnesses) -- deleting its `def` would have broken
all three. `#front_tile` has no such reference anywhere in the repository.

## Decision

Deleting a method's checked-in `def` outright requires a second,
independent check beyond bc2cpp.rb's own diagnostic:
**`scripts/bc2cpp_def_deletion_safety_check.rb <name>`**, a deliberately
blunt, whole-repository, `3rd/`-and-build-output-excluded text search. Not
another whole-program bytecode/AST analysis -- the point is precisely to
see the file kinds (tests, check scripts, docs) bc2cpp.rb's own scan was
never built to read. A false positive (the name inside an unrelated
comment, or as a substring of another identifier) only ever costs a manual
look, matching this codebase's usual "a missed match is dangerous, a wrong
match is merely annoying" asymmetry.

Only a method that is BOTH on bc2cpp.rb's own "never called" list (or
already had its registration pruned per docs/adr/0193) AND clean on this
repo-wide check is a candidate for outright `def` deletion. This session
ran it for real against both names above: `front_tile` came back clean
(deleted); `maker` came back with real, load-bearing references (left
alone -- its docs/adr/0193 registration pruning stands, its `def` does not
get touched).

`Game::Character#front_tile`'s `def` (`mruby-rpg2k/mrblib/game.rb`) is
deleted, along with its own preceding doc comment. `tools/bc2cpp/
compiled_gems.rb`'s own `Game::Character` narrative comment (which named
`#front_tile` as one of two non-mandatory-arity compile gaps) is updated to
note the method no longer exists at all, rather than left to describe a
method that is no longer real.

## Consequences

- This is a genuinely small, single-method result this round (`#maker`
  turned out to be the more interesting finding: a real, concrete
  confirmation that "never called" per bc2cpp.rb's own scope is not the
  same claim as "dead code," and that the gap between them is real, not
  theoretical).
- `scripts/bc2cpp_def_deletion_safety_check.rb` is the reusable
  infrastructure for future rounds: every future def-deletion candidate
  (whether surfaced by docs/adr/0193's own mechanism growing its safe-owner
  set, or by any other means) runs through it before the `def` comes out.
- Unlike docs/adr/0193's own registration pruning (which is inherently
  low-risk -- the interpreted fallback means a missed call site costs
  nothing but native-execution speed), this tier has a real correctness
  cost if the safety check is skipped or its blind spots (a call assembled
  via `send` with a computed, non-literal string; a reference from tooling
  outside this repository entirely, e.g. an external test harness) are hit.
  Treat every future use of this tier with the same caution this one
  round needed.
