- **`Scene::Map#step_parallels` no longer allocates a Proc/closure every
  frame just to drive its own loop.** The last of this round's
  `RGSS::Profiler.stats[:object_types]`-driven fixes: every background
  Parallel Process common event's per-frame step ran through
  `@parallels.dup.each { |p| step_parallel(p) }`, and in mruby a block
  literal allocates a real Proc plus its closure env on every call, not just
  the first — confirmed by measurement, not assumed. Rewritten as a plain
  `while` loop over the same defensive `@parallels.dup` snapshot (still
  needed: an Erase Event running inside a parallel process can remove entries
  from the live `@parallels` mid-loop — see `#erase_event`), which needs no
  block at all. mruby's `for`/`in` was checked as an alternative and ruled
  out: its compiler (`codegen_for` in mruby's `codegen.c`) desugars it to the
  exact same `#each` call, so it would have cost the same. `#step_battle_owner_parallel`'s
  `@parallels.find { }` (the mutually-exclusive in-battle counterpart, active
  only while a Parallel Process's own fight is running) got the same
  treatment for consistency.

  Measured with the same temporary per-frame instrumentation used for this
  round's other fixes (reverted before commit), clean A/B on the identical
  deterministic Nepheshel run: **Proc allocations 44.6 → 43.6 per frame, env
  33.6 → 32.6** — exactly one Proc and one env removed, matching the fix
  exactly (Nepheshel keeps at least one background Parallel Process running
  throughout, so `@parallels` is never empty in this run).

  Verified against `scripts/rpg2k_command_soak.rb` (368,332 real event
  commands across both Nepheshel variants) and `scripts/rpg2k_scene_check.rb`,
  which directly exercises the mid-loop-erase invariant this rewrite has to
  preserve ("Erase Event stops a parallel process that erases itself"), plus
  the rest of the RPG2000 logic/render checks — all pass, unchanged.
