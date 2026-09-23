# 0212. Lint the closed-world Ruby that bc2cpp compiles

Date: 2026-09-23

## Status

Accepted

## Context

bc2cpp compiles the mrblib of mruby-rpg2k, mruby-lcf and mruby-rgss as one
closed world. A devirtualized call site can drop its dynamic fallback only when
the analysis sees every method the call could reach. Some Ruby hides methods
from that analysis: `method_missing`, `send` with a computed name,
`const_get`, ivar reflection, `define_method`/`alias`/`undef`, the `eval`
family, `extend` on another object, and `expr rescue value` used as control
flow. Nothing stopped new code from adding more of them, and the closed-world
build mode for flash-limited targets depends on there being fewer.

## Decision

`scripts/rpg2k_closed_world_lint.rb` is a RuboCop-style checker built on
CRuby's bundled Prism, so it adds no gem. It has one cop per construct, runs
over those three gems' mrblib, and keeps existing offences in
`scripts/rpg2k_closed_world_lint_baseline.txt`:

- An offence not in the baseline fails.
- A baseline entry that no longer occurs also fails, so the baseline only
  shrinks. `--regenerate-baseline` refuses to add entries unless given
  `--accept-new`.
- A genuinely data-driven use can be allowed in place with
  `# rpg2k-lint:allow Cop/Name -- reason`, where the reason is required.

`scripts/rpg2k_closed_world_lint_check.rb` tests every cop, the look-alikes it
must ignore, and the allow-comment rules. Both run in the CI `ruby-checks`
job.

## Consequences

At introduction the baseline holds 70 offences in 30 files: 38 computed
`send`, 14 rescue modifiers, 8 `method_missing`/`respond_to_missing?`, 5
dynamic method definitions, 3 ivar reflections and 2 const reflections. New
dynamic Ruby now needs an explicit, reasoned exception. The lint is a
source-level guard; bc2cpp's own analysis remains what proves a site, and it
must still treat whatever the lint allows as dynamic.
