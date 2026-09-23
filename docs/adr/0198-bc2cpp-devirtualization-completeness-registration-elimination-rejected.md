# 198. Rejected: eliminating registration via devirtualization completeness

Date: 2026-09-22

## Status

Rejected

## Context

docs/adr/0193's "never called" registration pruning is close to exhausted
at this project's current bc2cpp coverage: exactly 2 real candidates found
across `mruby-rpg2k-compiled`/`mruby-lcf-compiled` combined (well over
1,500 real compiled methods), 0 in `mruby-rgss-compiled` after an
exhaustive per-entry audit (docs/adr/0195). A `register.cxx` line's only
purpose is making a method reachable via mruby's own dynamic method-table
lookup. A different, second question: for a **MONO** name (bc2cpp.rb's own
registry concept -- exactly one real definition project-wide) where every
real call site devirtualizes to a direct C++ call, does the registration
become unnecessary too, since nothing ever performs a runtime lookup for
it -- independent of whether any call exists at all?

## Decision

**Rejected as unsound at this project's current, partial bc2cpp coverage.**
Investigated, not assumed:

**Devirtualization is a per-call-site decision, never a per-name
guarantee.** Reading `compile_send` and every `monomorphic_target` call
site in `tools/bc2cpp/bc2cpp.rb`: a MONO name's devirtualization success is
independently gated per call site by arity-range checks
(`pure_mandatory_or_optional_arity?`), the emitting gem's own
`ONLY_OWNERS`/`OTHER_OWNERS` scope, whether the callee's own body compiles
clean at all (`monomorphic_target`'s own recursive `compiles_clean?`
check), `MONO_EMBED_GUARD`'s own runtime-guarded fallback for
ivar-embedding owners (a "devirtualized" call there still carries a live
`mrb_funcall` fallback branch), and separate, narrower guard logic for
keyword/splat call sites of the identical name. The codegen's own comment
(Step 7, just above `class CodeGen`) states the registered wrapper's
purpose directly: "so the method is still reachable the normal way --
from interpreted code, via `#send`, or from a call site this analysis
could not prove monomorphic." The file documents, in its own words, that
registration exists precisely because devirtualization is per-call-site
and incomplete, not a name-wide fact.

**The harder, dispositive problem: interpreted bytecode is never
devirtualized at all.** bc2cpp.rb only rewrites SEND/SSEND ops inside
method bodies it itself transpiles. A SEND op inside a method that stays
interpreted runs through mruby's real VM (`OP_SEND`), which unconditionally
does a real method-table lookup -- there is no "this name is MONO, skip the
lookup" concept anywhere in the interpreter. Proving no runtime lookup will
ever happen for a name therefore requires proving every real caller,
everywhere in the closed world -- not just the callers bc2cpp itself
compiles -- is both itself compiled AND devirtualizes at that specific call
site. No existing tooling tracks this: `collect_static_call_target_names`
(the "never called" diagnostic's own whole-program pass) only answers "does
a call site naming this exist at all," a strictly weaker, presence-only
question with no concept of whether any given call site resolved
statically.

**A concrete, verified counterexample, not a hypothetical.** `LCF::
EventCommand#code`/`#indent` are real, currently-registered MONO names
(confirmed against a real host bc2cpp.rb run for `mruby-lcf-compiled`).
`Game::Interpreter#skip_to`/`#do_show_choices` (`mruby-rpg2k/mrblib/
interpreter.rb`) call both by name repeatedly, and `mruby-rpg2k-compiled/
src/register.cxx`'s own comment names both methods as staying permanently
interpreted at this coverage level (an unmodeled `JMPUW` opcode gap in the
*caller*, unrelated to `code`/`indent` themselves). Those SEND ops are
real, live, permanent dynamic dispatches -- exercised by ordinary shop/
inn/battle-resume and show-choices flows, not an edge case -- that would
regress to a real `NoMethodError` if either registration were dropped.

A second, separately unresolved problem: even if devirtualization
completeness *were* provable, no reflective-access check exists for
general `send(computed_name)` (`always_reachable`, docs/adr/0193's own
exception list, only covers a short list of mruby-core-triggered magic
methods) -- the same residual blind spot docs/adr/0194 already flagged for
a different tier of this same mechanism.

## Consequences

- No code change. This is a documented negative result, not a missed
  opportunity to revisit casually -- the counterexample is structural
  (partial bc2cpp coverage leaves real interpreted callers of compiled-and-
  MONO names, and will keep doing so until coverage is much closer to
  100%), not a bug to fix in this analysis.
- Revisiting this would need, at minimum: a real whole-program pass
  tracking devirtualization success per individual call site (not just
  per-name presence, what Step 6h's diagnostic already does), proof that
  pass covers every SEND in the closed world including ones inside
  never-compiled methods, and a real answer to the reflective-access gap.
  All three are nontrivial, and the second is unlikely to hold broadly
  until bc2cpp's own coverage (currently well under 100% of real methods,
  per every `register.cxx`'s own "N of M compile clean" accounting) grows
  much closer to complete.
- docs/adr/0193's own mechanism (registration pruning gated on zero call
  evidence, with the interpreted `def` left as a safety net) remains the
  sound lever for this problem; this ADR does not change that mechanism's
  scope or conclusions.
