# 202. Leave mruby-kernel-ext and mruby-random out of the Wio Terminal build

Date: 2026-09-22

## Status

Accepted

## Context

`rpg_maker_gems` in `build_config.rb` gives every target the same list of
core mruby gems. Some of those gems are there only for a game's **own** Ruby,
and their comments say so:

- **mruby-kernel-ext** (`Integer()`, `Float()`, `String()`, `Array()`,
  `Hash()`, `fail`, `caller`, `__method__`, `__callee__`): "every RGSS game
  clamps its battler stats through it ... community scripts reach for".
- **mruby-random** (`Kernel#rand`/`srand`, `Random`, `Array#shuffle`/
  `#sample`): "a game's own scripts roll dice constantly ... This engine's own
  code deliberately uses seeded LCGs instead ... which is why the gem was
  never needed until games ran their own code."

docs/adr/0140 and 0141 declined to trim `Math`/`Time` on the same grounds:
a game's community scripts might call them. That reasoning does not apply to
Wio. It is `single_format_only` (docs/adr/0098) and ships mruby-rpg2k alone.
RPG2000/2003 games contain no Ruby, and Wio's build links no `mruby-compiler`
or `mruby-eval`, so there is no way to run any. On Wio, the only Ruby that
can call these methods is the engine's own gems.

The Wio build links mruby-rpg2k, mruby-lcf and mruby-rgss (`mrblib` and
`src`), mruby-marshal, mruby-stringio, and the core gems. I checked which of
them use either gem:

- **Ruby:** parsed with `Ripper.sexp` rather than grepped, so that a local
  variable called `sample` or a comment mentioning `rand` does not count.
  There are zero calls to any method either gem provides, and zero
  references to `Random`.
- **C/C++:** zero `mrb_funcall`-style lookups of those names.
- **Core gems' own `mrblib`, and the `add_dependency` graph:** no users, and
  neither gem is a dependency of anything Wio links. Fiber, for example, is a
  different case: `mruby-stringio` needs mruby-enumerator, which needs
  mruby-fiber, so it stays.

`exit`, `String#%`, `Math.sin` and `Time.now` all have real callers in
mruby-rpg2k. So mruby-exit, mruby-sprintf, mruby-math and mruby-time stay.

## Decision

- `build_config.rb`: `conf.gem core: 'mruby-kernel-ext' unless conf.name ==
  'wio'`, and the same for `mruby-random`, with a comment giving the reason.
  Only Wio changes. PSP and maix are also `single_format_only` and could
  follow, but they were not measured here, so they keep both gems.
- **`scripts/wio_dropped_gems_check.rb`**, a new check wired into CI's
  `ruby-checks` job. Nothing else would catch a regression: CI never runs a
  Wio build, so a future `rand(3)` or `Integer(x)` in mruby-rpg2k would pass
  every host check and raise `NoMethodError` only on the board. The check
  runs the `Ripper.sexp` scan above over every `.rb` in the Wio-linked gems.
  It scans all files, not just the subset Wio's `mrbgem.rake` filters keep,
  so it errs toward failing. It also scans their C/C++ for name lookups. It
  carries its own sensitivity self-test: every forbidden form must be
  caught, and the look-alikes (a local `sample`, `Integer === x`,
  `class Integer`, strings and comments) must not be. Planting a
  `rand(2)` in a scratch copy of the tree made it fail as expected.

## What was verified

Real cross-builds, not only relinks: two fresh `MRUBY_TARGET=wio rake` runs
from the same tree, one with each `build_config.rb` (same recipe as
`scripts/wio_bc2cpp_measure.bash`). Each `pio run -e wio_rgss_boot` was
serialized with `flock`. The measurements are on top of docs/adr/0201:

| build | before | after | delta |
| --- | ---: | ---: | ---: |
| `wio_rgss_boot` baseline, FLASH overflow | 643,768 | 639,788 | -3,980 |

(The `RPGMAKER_BC2CPP=1` pair of cross-builds takes about 15 minutes; its
row is added once measured.)

The rebuilt "before" baseline `libmruby.a` reproduces docs/adr/0201's
643,768 exactly. That confirms rebuilding the library against 0200/0201's
`lv_conf.h` changed nothing in it, and that this row isolates this change
alone. Both links resolve every symbol. Wio's `mrbgems/` build directory no
longer contains either gem.

## What was not verified

- No boot on hardware or under Renode. What stands in for one: the proof
  above that nothing calls these methods, and the CI check that keeps it
  that way.

## Consequences

- About 4 KB less flash. It is small because both gems are small; the point
  is to make the "no user Ruby on Wio" argument explicit in the build, so it
  can be applied again.
- That argument covers more than these two gems. docs/adr/0140/0141 left
  `Math`'s unused functions (erf, cbrt, the hyperbolics, ...) and `Time`'s
  unused accessors alone because a game's scripts might call them. On Wio
  no game script exists, so what remains is only a matter of how the
  engine's own calls are kept in check, which this ADR's check shows how to
  do.
- Adding a `rand`/`Integer()`/`fail`/... call to the engine now fails CI.
  The check's message says what to do: drop the call, or give the gem back
  to Wio and re-measure.
