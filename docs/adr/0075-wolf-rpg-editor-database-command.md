# 75. WOLF RPG Editor Database(250): the plain read/write case

Date: 2026-09-07

## Status

Accepted

## Context

`Database`(250) ("ＤＢ操作", WolfTL's own name; the wolfrpg-map-parser crate
calls it `db_management_command`) is by far the most common unimplemented
command left in the sample game: 2544 real occurrences across 225 Common
Events, more than any other command this project has implemented so far.
The manual (help/04ev_db.html) documents a command far larger than the
crate's own model: four target kinds (可変DB/システムDB/ユーザDB, each a
numbered `DBType`, plus XY配列 -- a 2D numeric array with its own addressing,
outside `DBType`'s 0-2 range entirely), two top-level operations (write,
available only for 可変DB/XY配列; read, the only option for システムDB/
ユーザDB), and a long tail of utilities in the same command dialog: eight
name<->index lookups, whole-type/whole-datum reset, four data-shuffling
operations (insert/extract/copy/sort), and CSV import/export (a separate
command, `ImportDatabase`(251)). This ADR scopes tightly to the plain
read/write case, per `docs/TODO.md`'s own "suggested next order" note from
the prior PR.

The crate's own `DBManagementCommand` struct maps cleanly onto this
reader's `arg(N)` framing (unlike `Choices`(102)/`Sound`(140), whose crate
models needed real data to reconcile at all): `db_type`/`data`/`field`
(`arg(0..2)`) each a `ValueRef`-decodable reference like any other numeric
slot -- real data uses variable-held selectors, not just literals -- and a
packed `arg(3)` combining the crate's own `Assignment`(byte 0)/
`Options`(byte 1) bytes. Byte 0's high nibble is the assignment operator,
byte-for-byte identical to `SetVariable`(121)/`SetVariableEx`(124)'s own
already-cross-confirmed 0-8 numbering, reused here via `#apply_assign_op`
(and a new `#apply_assign_op_string`, string fields' own 0/1 subset -- see
below); its low bit is `use_variable_as_reference`, 0 in every one of the
2544 real calls, so name-lookup mode is left unimplemented rather than
guessed. Byte 1's low nibble is a `DBType` (0 可変DB, 1 システムDB, 2
ユーザDB) and high nibble Write(0)/Read(1).

The crate's own comment calls the packed word's third byte padding, but it
is non-zero in every real call. Decoded here (a 3-bit "which of the three
optional 名前で呼出 strings this call carries" flag) it never disagrees with
the strings' own emptiness -- and cross-checking those strings directly
against the parsed database (`user_db[2].name == "アイテム"` for CE#0's own
"○アイテム増減", matching its own embedded string byte for byte, repeated
across dozens of real examples) confirms they are the editor's own
auto-filled display labels for the current *numeric* selection, not a live
name-lookup trigger -- one real call (`CE#3`'s own "○お金の増減") even
carries a stale label ("用語設定") that names no real database type at
all, which a numeric-selector-only implementation tolerates fine and a
name-driven one could not. So the third byte adds nothing beyond what
`cmd.strings` already carries, and the strings themselves are not read.

A real command shape this reader had not planned for surfaced during
implementation: which of `var_store.number`/`.string` a call's value goes
through is not carried by the packed word at all -- it is decided by the
target `DBField`'s own `#string?`. `CE#0`'s own real command reads user DB
type 2's own "アイテム名" field (a string) into common-event self-var 8
(help/06valueget.html's own self-var 5-9 string band); treating that as a
number the way a first-pass implementation naturally would silently
coerces it to 0 and fires `VarStore`'s own type-mismatch warning on every
call. Fixed by branching on the field's own type before choosing which
`VarStore` accessor to call, mirroring real string-field Read/Write/
PlusEquals(concatenation) calls the sample game genuinely makes.

Exercising all 2544 real calls this way surfaced a second, deeper issue:
`VarStore#number`/`#string` read self-variable/variable banks (plain
untyped Hashes, since `set_number`/`set_string` share the same slot)
without checking the stored value's own type, so a slot last written as a
String and later read as a number reached `fold32`/`apply_assign_op`'s
arithmetic directly and raised a real `TypeError`/`NoMethodError` --
reachable in real WOLF projects any time a self-var's last write and next
read disagree on type (a legitimate scripting pattern WOLF does not
prohibit, and self-var banks persist across a common event's own separate
invocations, so a stale type from a prior run is enough). Fixed alongside
this command, not filed as a follow-up, the same precedent ADR 0074 set
for `SetVariable`(121)'s own `.zero?` bug: `VarStore#number` now coerces
every Hash-backed bank read through a new `#coerce_number` (mirroring
`db_number`'s/`common_self_string`'s own pre-existing defensive `is_a?`
checks), warning once and treating the value as 0 rather than crashing.

## Decision

- `#exec_database` accepts the 5-argument shape (db type/data/field/packed
  word/value-or-target -- the dominant real shape, WolfTL/the crate's own
  `Base` state) and the 4-argument shape (19 real, all Write, the value
  being the command's own lone string, the crate's own `String` state);
  every other argument count, an unrecognized `DBType` selector, and
  `use_variable_as_reference` are logged and skipped.
- The target field's own `#string?` selects `#exec_database_number` or
  `#exec_database_string`. Both apply the identical
  current/computed-then-assign-op pattern SetVariable/SetVariableEx
  already use, current and computed simply swapped between Read (DB's own
  value combined with the target's current value, written to the target)
  and Write (DB's own value combined with the resolved source, written
  back into the DB) -- confirmed by a real `MinusEquals` member-management
  call that decrements an invoker-tracking field by 1 rather than
  overwriting it, and real string `PlusEquals` calls that concatenate.
- `DBDatum#[]=`/`DBType#set_value` are new (`data.rb` had no DB writer at
  all before this).
- `VarStore#number` gained `#coerce_number`, applied to every Hash-backed
  variable/self-variable bank read.

## Consequences

- The sample game's own real inventory/equipment (item/weapon/armor
  count and name lookups), currency-unit, and member-management Database
  calls now run for real, end to end (soak check, `ctest -R mruby_test`,
  and the compiled binary against the real sample game all exercise it
  with zero new crashes).
- `VarStore#number`'s new defensive coercion protects every other command
  that calls it too, not just this one -- the same "found and fixed
  alongside" precedent ADR 0074 set.
- Still unimplemented: XY配列 (a whole second, non-`DBType` target with its
  own addressing), every DB操作 utility beyond plain read/write (the eight
  name<->index lookups, データ数/項目数取得, 全データ初期化, and the four
  data-shuffling operations insert/extract/copy/sort), name-lookup mode
  (`use_variable_as_reference`, never observed in real data), and CSV
  import/export (`ImportDatabase`(251), a separate command).
