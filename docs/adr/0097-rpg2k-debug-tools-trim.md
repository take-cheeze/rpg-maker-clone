# 97. psp/wio drop RPG_RT's own debug tools from mruby-rpg2k

Date: 2026-09-07

## Status

Accepted

## Context

ADR 0007's flash budget for the Wio Terminal (512 KB internal flash) lists
gem trimming as a lever "to be measured," not assumed — the uni-algo trim
(`cmake/uni-algo-trim.cmake`) is the one lever that ADR has actually landed
so far. Looking for the next one, profiling `mruby-rpg2k`'s compiled
`mrblib` (each file's own `mrbc -g` output, walked with `mrb_read_irep_file`
and `mrb_debug_get_filename`/`mrb_debug_get_line` to attribute every irep
node back to its source) shows it costs 413,612 bytes of iseq+pool+syms —
the single largest gem in the whole game, well ahead of `mruby-wolf`
(82,367) or `mruby-lcf` (36,200).

Three of its 19 mrblib files are not part of the engine a player ever
reaches: `scene/debug_menu.rb`, `scene/chipset_editor.rb` and
`scene/map_viewer.rb` implement RPG_RT's own F9 debug menu (a Switch/
Variable browser, a chipset passability editor, and a whole-map overview) —
Test Play tooling, not gameplay. Every real call site already says so:

- `Scene::Map#try_open_debug_menu`: `return unless @parent.test_play` before
  ever touching `Scene::DebugMenu`.
- `main.rb`'s `open_map_editor`/`open_chipset_editor` (the
  `--rpg2k_map_editor`/`--rpg2k_chipset_editor` CLI dev flags) both already
  `rescue StandardError => e` around the `Scene::MapViewer.new`/
  `Scene::ChipsetEditor.new` call, printing a message rather than crashing.

A released game — and certainly a game running headless on a handheld with
no keyboard to type `--rpg2k_chipset_editor` — never executes any of this.
Nothing else in the engine calls into any of the three files (`grep -rn
"DebugMenu\|ChipsetEditor\|MapViewer" mruby-rpg2k/mrblib` turns up only the
four call sites above and their own cross-references to each other).

## Decision

`mruby-rpg2k/mrbgem.rake` drops the three files from `spec.rbfiles` when
`build.name` is `psp` or `wio` — the same `%w[psp wio]` grouping
`mruby-rgss/mrbgem.rake` already uses for its own pthread-linking guard
(checking *this* cross build's own name, not the host half of the same rake
run that also produces `mrbc`). Desktop, wasm and Android keep all 19 files;
a developer testing on desktop still gets F9, the map viewer and the
chipset editor exactly as before.

Measured by compiling `mrblib/**/*.rb` with real `mrbc -g`, with and without
the three files:

| | full | trimmed | |
| --- | --- | --- | --- |
| own bytecode (iseq+pool+syms) | 413,612 B | 395,353 B | −18,259 B (−4.4%) |
| RITE binary (`-g`, includes debug tables) | 811,360 B | 777,752 B | −33,608 B |

`Scene::Map#try_open_debug_menu` gets one defensive line,
`return unless defined?(Scene::DebugMenu)`, ahead of the
`Scene::DebugMenu.new` call: `@parent.test_play` already keeps a released
game from reaching it, but nothing enforces that a future build flag can
never flip `test_play` on for a psp/wio binary too, and a no-op is a cheap
guard against that turning into a `NameError` instead. The two CLI flag
handlers needed no change — they were already exception-safe.

## Consequences

- **A real, if modest, flash saving for the two targets that are actually
  flash-constrained.** 18 KB is under 5% of `mruby-rpg2k` alone and well
  under 1% of the whole game's ~639 KB mrblib footprint across every gem,
  but it is genuinely player-unreachable code on psp/wio, at essentially no
  risk: the three files have no callers left once excluded, and the one
  call site that could reach them is now a guarded no-op instead of a dead
  reference.
- **Asymmetric by design.** A desktop or wasm build (and Android, whose
  storage is not the constraint the Wio's 512 KB internal flash is) keeps
  the debug tools; only the two cross-builds ADR 0007/0010 already treat as
  tight lose them. If a future target needs the same trim, add its
  `build.name` to the same array rather than inventing a new mechanism.
- **This does not move the needle on ADR 0007's actual blocker.** That ADR's
  own text is explicit: onigmo and uni-algo's tables (already trimmed) are
  the multi-hundred-KB items; this is a much smaller, easy-to-verify cut
  found by actually profiling the compiled bytecode rather than guessing at
  which files are big. `mruby-rpg2k/game.rb` alone (141,855 B) and
  `scene/map.rb` (102,253 B) dwarf this trim and are not optional — they are
  the field engine itself.
- **A hash-literal-to-array-literal rewrite of `mruby-lcf/mrblib/schema.rb`
  (its `module Schema` body alone is 26,138 B, 72% of that gem) was
  measured and rejected in the same investigation**: a representative A/B
  compile projected roughly a 20% cut to that one block (~5.4 KB, under 1%
  of the whole project's bytecode) against rewriting ~930 field literals by
  hand in the file that decodes every real `.ldb`/`.lmu` field — the same
  "measured, not worth the risk" call ADR 0047's Finding 5 made for
  `mrbc --remove-lv`. Recorded here rather than in `schema.rb` itself so the
  next person looking for a schema.rb win finds the answer without redoing
  the measurement.
