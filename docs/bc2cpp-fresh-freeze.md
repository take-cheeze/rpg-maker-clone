# Freezing fresh builtin results (FRESH_BUILTIN_FREEZE)

A compiled store into an embedded ivar skips mruby's frozen test when the closed world proves that no
instance of a user class is ever frozen (`ClosedWorld#user_objects_unfrozen?`). Before this change, every
`freeze` in the program's own Ruby had to be aimed at a builtin literal (`[...]`, `{...}`, a String, a Range)
or at a class constant. A single `(0..0x7fff).map { ... }.freeze`, like the one in optcarrot's
`PPU#setup_lut`, therefore put the frozen test back on every embedded store in the program.

`fresh_builtin_result?` (tools/bc2cpp/closed_world.rb) also accepts a receiver produced by a core iterator
that returns a new Array or Hash (`map`, `collect`, `select`, `filter`, `reject`, `flat_map`,
`collect_concat`, `sort`, `sort_by`, `to_a`, `entries`, `zip`, `uniq`, `compact`, `reverse`). The iterator's
own receiver must be a builtin literal or another such result, on every path (the same dominance walk as the
literal case). Such a result is a builtin value, never a user object, as long as only mruby's own code defines
the iterator. After the scan, `fresh_builtin_names_core?` confirms that for each accepted name:

- no computed definer can install it;
- every Ruby definition in the registry and every outside Ruby definer is core Ruby (`CoreDefs.core_source?`);
- every native source that spells it is part of 3rd/mruby.

A user `class Range; def map; ...; end; end`, a `freeze` of anything else, or `:freeze` spelled where a
computed send could reach it still keeps the test. `BC2CPP_FRESH_FREEZE=0` restores the old refusal, for
comparison.

`MRBC=path/to/mrbc ruby scripts/bc2cpp/fresh_freeze_check.rb` asserts that a store loses its frozen test in
a world whose only freeze is of `(0...n).map { }.select(&:even?)`, and keeps it for a freeze of a user object,
for a user-defined `map` and under `BC2CPP_FRESH_FREEZE=0`. It also compares interpreted and compiled runs.

In the optcarrot probe (Lan_Master, callgrind, instructions per frame from the difference of 21-frame and
1-frame runs), every one of the 830 frozen tests goes away, and the frame loop drops from 42.72M to 40.83M
instructions.
