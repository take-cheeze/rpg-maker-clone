# 0425. bc2cpp: a frozen-table slot that is `LITERAL.freeze` takes the literal's container class

Date: 2026-10-12

## Status

Accepted

## Context

ADR 0306 classes each slot of a frozen literal table from the op that wrote it: `LOADI*`, `STRING`, `ARRAY`,
`HASH`, a range, a constant proven Integer. A slot written by a `freeze` call (`[[1, 2].freeze, 3].freeze`) fell to
OTHER, although `[1, 2].freeze` is an Array. The result is worse than the unfrozen spelling: `TURN_RIGHT` written
with unfrozen inner arrays is `FROZEN:Hash[INT*4,ARR*4]`, and with `.freeze` on the inner arrays it is
`FROZEN:Hash[INT*4,OTHER*4]`.

A nested read (`TABLE[k][j]`) is the other gap. Following a slot into the inner literal's own shape would type it,
but only under conditions the proof does not yet state.

## Decision

Part (a), built, kill switch `BC2CPP_FREEZE_SLOT=0`. `frozen_table_slot_mask` classes a slot whose single reaching
writer is a `SEND0 :freeze` with the same register as the single `ARRAY`/`HASH` op right before it (the rule the
literal's own shape already uses, `frozen_table_freeze_literal`) as ARR for an Array and HSH for a Hash. Soundness:

- `Kernel#freeze` answers its receiver, and `frozen_table_name_safe?('freeze', klass)` refuses the rule when any
  Ruby or native definition of `freeze` on the literal's ancestors (or an installer, or an unknown mixin) could
  change that. A refused name makes the outer literal no table at all, as before.
- The literal is fresh and frozen by the adjacent `freeze`, so no alias exists. The slot therefore holds that exact
  Array or Hash. ARR and HSH are the classes an unfrozen literal of the same container already gives its slot.
- Only the class is claimed. The inner table's own slots are not followed into.

Part (b), following a nested literal into its inner shape, is not built. The measurements below show no read it
would change: in the engine, every nested read of a frozen table has a computed outer key (`GRID_TABLE_0[n][i]`,
`MSG_COLORS[idx]`, `TURN_*[dir]`), and no mrblib source has a literal-key read of a literal-key read. Its
conditions (a literal outer key that resolves to one slot, a proven Integer or Symbol key set on the outer, a literal
inner key) would also need a use analysis of the outer read's result, which the flow does not carry. Without a
consumer it adds soundness surface for no measured gain, so it is declined here and recorded as the next slice if a
real shape needs it.

## Measurements

Wio closed world, `scripts/bc2cpp/coverage_report.rb` with `BC2CPP_COVERAGE_KEEP_DIR` and `BC2CPP_ELEMENT_REPORT`.

- Shipped tree, master vs this branch with `BC2CPP_FREEZE_SLOT=0`: generated `shipped.cxx`, stderr, stdout and the
  element TSV are byte-identical (431,695 lines, 21,005,028 bytes; 1,374,515 stderr bytes).
- Shipped tree with the rule on: identical in all four outputs. No shipped table has a slot written by
  `freeze` (the inner arrays of `TURN_*`, `MSG_COLORS` and `GRID_TABLE_0` are not frozen in the source), so the census
  stays 49 shapes and the code does not change.
- Variant (a copy with the inner literals of `TURN_*`, `MSG_COLORS` and `GRID_TABLE_0` frozen, the shape the
  investigation described), switch off vs on: the generated C++ is identical (431,695 lines), the census is 57 shapes
  in both, and the shape names change:

| constant | shape off | shape on | read (model, `FrozenTables::Registry#read`) off | on |
| --- | --- | --- | --- | --- |
| `TURN_RIGHT/LEFT/180[dir]` (computed key) | `INT\|FROZEN:Hash[INT*4,OTHER*4]` | `INT\|FROZEN:Hash[INT*4,ARR*4]` | INT\|OTHER\|NIL | INT\|ARR\|NIL |
| `MSG_COLORS[idx]` (computed key) | `FROZEN:Hash[OTHER*10]` | `FROZEN:Hash[ARR*10]` | OTHER\|NIL | ARR\|NIL |
| `MSG_COLORS[0]` (literal key present) | `FROZEN:Hash[OTHER*10]` | same | OTHER | ARR |
| `GRID_TABLE_0[n]` (Integer index) | `FROZEN:Array[OTHER*8]` | `FROZEN:Array[ARR*8]` | OTHER\|NIL | ARR\|NIL |

The `TURN_*` literal key read (`TURN_RIGHT[8]`) is not proven in either state: the outer keys include Array keys,
so the key proof of ADR 0306 does not hold and the read is `joined|NIL`. The reads change class only; none of them
selects a different arm in the generated code, so the variant's C++ does not move.

## Consequences

- The class of an element read from a table whose slot is a frozen literal is now ARR (or HSH) where it was OTHER.
  Each consumer of an ARR class already handles the unfrozen spelling of the same literal.
- No measured code change: the shipped tree, the switch-off tree and the variant all emit the same C++ on and off.
  The gain is a more accurate model for future reads with literal keys, not a size or speed change today.
- Bare-name collision: `TURN_*` also names `MoveRoute` commands (`game.rb` line 6728). The table reads here are the
  `Game::Character` constants only; the collision is not fixed by this change.
- The part (b) slice stays open. Its conditions are above; it needs a consumer before it is built.

## Tests

`scripts/bc2cpp/frozen_slot_check.rb`: a host section on hand-built bytecode in the register layout mrbc emits (the
nested, `dup`, double-freeze and non-adjacent cases, switch on and off, a refused `freeze` name), and an MRBC section
on compiled fixtures. Listed in `.github/workflows/build.yml` (host) and `bc2cpp-nightly.yml` (MRBC) and in
`scripts/coverage/report.rb`.
