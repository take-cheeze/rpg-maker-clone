# 98. psp/wio compile RPG2000/2003 only

Date: 2026-09-08

## Status

Accepted

## Context

`rpg_maker_gems` (`build_config.rb`) builds one mruby image that can run
*any* RPG Maker format this project supports — `src/main.cxx` looks at a
game directory on disk (`RPG_RT.ldb` / `Game.ini` / `.rvdata*` /
`js/rpg_core.js`) and starts the matching maker at runtime, with
`rpg_maker_gem_dispatch` deferring which maker's own gems actually
initialize (ADR 0047 Finding 1: `mrb_open()`'s flat `mrb_init_mrbgems()`
would otherwise eagerly bring up every maker's classes whichever one a run
needs). That dispatch already solves the *runtime heap* cost of carrying
four RPG Maker formats. It does nothing for *flash*: `mruby-rpgxp`,
`mruby-rpgvx`, `mruby-wolf` and `mruby-mvjs` are compiled into every
build's `libmruby.a` regardless, because desktop/wasm/android are exactly
the "any format, chosen at runtime" targets that design serves.

psp and wio are not. ADR 0061/0091/0097 have never run anything but
RPG2000/2003 on either, and ADR 0007/0010 already single them out as the
two flash/storage-constrained targets in this project. Profiled with real
`mrbc -g` (the same method ADR 0097 used):

| gem | bytes | used by psp/wio? |
| --- | --- | --- |
| mruby-rpgxp | 30,812 | no |
| mruby-rpgvx | 11,994 | no (depends on rpgxp) |
| mruby-wolf | 82,367 | no |
| mruby-mvjs | 44,291 | no (psp already excluded this one) |

125,173 bytes for psp (it already dropped mvjs via `include_mvjs: false`
for an unrelated reason — quickjs/GL can't cross-compile there), 169,464
for wio.

`mruby-onig-regexp` (onigmo, "easily hundreds of KB" per ADR 0007, not yet
measured on any bare-metal target because it has never finished
cross-compiling in a sandboxed dev environment — see Consequences) goes
with them. Checked (not assumed) whether it is actually needed: `Regexp`,
`=~`, `.match`/`.scan` and `Onig` references across `mruby-rpg2k`,
`mruby-lcf` and `mruby-rgss`'s own mrblib and C sources turn up nothing —
`mruby-rpg2k/mrblib/main.rb` even says so outright ("Parsed with core
string operations only -- this mruby build bundles neither a regexp
engine nor String#strip"). Every real call site is in a gem this ADR
already drops: `mruby-wolf`'s Picture window-shape tags
(`interpreter.rb:1145-1305`), `mruby-rpgxp`'s `Dir.glob` fallback
(`rgss_library.rb:352-366`), `mruby-mvjs`'s JSON/HTML scanning
(`mv.rb:365-1050`). Nothing left needs onigmo once those three are gone.

## Decision

`rpg_maker_gems(conf)` computes `single_format_only =
%w[psp wio].include?(conf.name)` and skips `mruby-onig-regexp`,
`mruby-rpgxp`, `mruby-rpgvx` and `mruby-wolf` (and folds `mvjs` into the
same condition) for exactly those two builds. Desktop, wasm and Android —
the targets that actually need to run whatever format a game directory
turns out to be — are unaffected; every gem stays, `conf.name` is never
`psp`/`wio` there.

`rpg_maker_gem_dispatch` takes a `single_format_only:` flag and shrinks
`maker_gem_names` to `%w[mruby-rpg2k]` under it, rather than special-casing
a separate code path: the closure/dispatch machinery it already had for
picking apart four makers' shared vs. private dependencies runs unchanged
over a list of one, generating a trivial `rpg_maker_init_rpg2k_gem` with
nothing to dispatch *between*. The one thing that needed an actual code
change is the C-generation step's `rpg2k, rpgxp, rpgvx, wolf, mvjs =
makers` line, which used to destructure a always-5-long array positionally
— now a `maker_gem_names.zip(makers).to_h.values_at(...)` lookup, so a
missing maker comes back `nil` by name rather than by position, and each
maker's `rpg_maker_init_*_gem` block is skipped when its gem is absent —
the same `if mvjs` guard `include_mvjs: false` already needed, now applied
uniformly instead of being mvjs's special case.

`src/main.cxx` (the desktop/wasm/android entry point that calls
`rpg_maker_init_rpgxp_gem`/`_wolf_gem`/`_mvjs_gem`) needed no change: it is
never compiled for psp (its own bring-up `main.cxx` under `app/psp/`) or
wio (which does not link `libmruby.a` at all yet), so the functions this
drops are never referenced by a psp/wio link in the first place.

## Consequences

- **A real flash win for the two targets it was named for**, at no
  behavior change for the three that keep every format. 125–169 KB of
  Ruby bytecode plus onigmo's own compiled size (unmeasured here, see
  below) is a meaningfully bigger cut than ADR 0097's 18 KB debug-tools
  trim, for the same reason: it targets code that build already never
  calls, rather than code that happens to be small.
- **This forecloses one thing on purpose**: a Wio Terminal or PSP build
  from this project can never run an XP/VX/VX Ace/WOLF/MV game, not just
  "doesn't today." If that ever needs to change for one of these two
  targets, the fix is deleting its name from the `%w[psp wio]` check, not
  inventing a new mechanism — the dispatch code already generalizes to any
  subset of makers.
- **onigmo's own real size on either target is still an estimate, not a
  measurement** — verifying it needs a working psp or wio C++ cross-link,
  and neither completed in the sandbox this ADR was written in for reasons
  unrelated to this change: onigmo's `./configure` step fails outright for
  the bare-metal `arm-none-eabi` target the same way with or without this
  ADR's diff (confirmed by reverting it and reproducing the identical
  failure), and getting past that reveals a second, also pre-existing gap
  (`arm-none-eabi-g++` here has no `<utility>` — no C++ standard library
  headers at all). Both are packaging gaps in this environment's toolchain
  install, not this repo's build; the real CI `wio`/`psp` jobs already
  build successfully today and will keep doing so, since this change only
  *removes* compilation units from a build that already worked. What *is*
  verified: the host build is untouched (still all seven maker/support
  gems, `ctest` 9/9 including `mruby_test`), and a real
  `MRUBY_TARGET=wio rake` run — before hitting the unrelated `<utility>`
  wall — shows `rpg_maker_gem_dispatch.c` generating correctly for a
  single-maker build and onigmo/wolf/rpgxp/rpgvx/mvjs never being invoked,
  confirming the exclusion actually fires rather than merely compiling.
- **`mruby-eval`/`mruby-binding` also drop out for psp/wio as a side
  effect** — they were only ever pulled in transitively via
  `mruby-rpgxp`'s own `add_dependency 'mruby-eval'` (confirmed via `grep
  add_dependency` across every maker gem's `mrbgem.rake`; nothing rpg2k/
  lcf/rgss keep depends on either). ADR 0047 Finding 5 rejected
  `mrbc --remove-lv` specifically because `mruby-eval`/`mruby-binding`
  read the local-variable table it would have stripped — that conflict no
  longer exists for a psp/wio build once this ADR lands, since neither gem
  is present to need it. Worth a real second look, not assumed safe by
  this ADR: a future change, not this one.
