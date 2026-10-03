# 0332. The `super` no-caller-block proof, derived instead of listed

Date: 2026-10-04

## Status

Accepted

## Context

`SUPER` has three translation paths in bc2cpp: an allowlisted direct `_impl`
call, a zsuper forward (`ARGARY` + `SUPER n=*`), and the module-super direct
call that ADR 0329 added (which forwards the frame's block).

The allowlisted path exists because of one fact. OP_SUPER always forwards the
current method's block, and a compiled `_impl` has no block parameter, so that
block would be dropped. That is only sound when no caller ever passes one --
which ADR 0146 established as `SUPER_TARGETS`, "human-vetted, re-check this for
every new entry". The cost is a list that must be re-audited by hand whenever a
caller appears, and nothing in the build notices when the audit is stale.

## Decision

Derive the fact instead, from the instructions the build already has.

A block reaches a method through a block-carrying send: `SENDB` / `SSENDB`, or
`&expr` beside a plain one. So if no instruction in the build sends `name` with a
block to a receiver that can be an instance of the owning class, none can
arrive. `super_direct_call_allowed?` answers that per `Owner#name`:

- `block_carrying_callers_of(name)` scans every compiled irep for a
  block-carrying send of the name and asks CALL_FACTS (ADR 0317) which classes
  that receiver can provably hold;
- `superclass_closure` closes a class over its subclasses, so a call proved to
  hold a *subclass* still counts as a possible caller;
- the proof holds only when **no** such send exists, or every one holds a class
  outside the closure.

Everything the scan cannot read is a refusal, never a pass: an open world
(`call_facts_enabled?` false -- no closed world or no native sources), a send
whose receiver class is unproven, an empty-but-unknown answer. `SUPER_TARGETS`
still short-circuits to `true`, so an entry vetted before this ADR keeps working
even where the scan would decline.

`BC2CPP_SUPER_DIRECT=0` restores the previous behaviour.

## Consequences

The `#error` count does not move: on the wio closed world every `super` that
compiles today was already allowlisted, and the derived proof agrees with the
hand-vetted list on all 72 methods it is asked about -- `true` exactly where the
list says so, and `newly admitted (not allowlisted): []`. What changes is that
the list is no longer the only thing standing between a new caller and a
silently dropped block: a `SENDB` appearing anywhere in the build now turns the
direct call off for that name automatically.

That agreement is also the useful negative result. The scan is not a licence to
add sites; it is a check that the allowlist has not rotted.

`scripts/bc2cpp_super_direct_check.rb` pins both directions in a closed world
(the scan refuses everything without one, which is the sound default): an
admission when no block-carrying caller exists, and a refusal for each way a
caller can appear -- same name, through a subclass, with an unproven receiver --
plus the per-name property and the kill switch.

`scripts/bc2cpp_fixture_runtime.rb` grows `skip_unsupported: false`, so a check
can assert on a refusal: `SKIP_UNSUPPORTED` drops a `#error`ed method whole, and
an absent body is indistinguishable from one that was never compiled.

Not run here: the 32-bit `mrb_int` leg, firmware smokes, optcarrot
open-world comparison.
