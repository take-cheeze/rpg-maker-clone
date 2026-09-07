- **WOLF RPG Editor (ウディタ/Woditor)** `Database`(250) now reads and writes
  a single field of the changeable/system/user database — by far the most
  common unimplemented command left (2544 real occurrences). Shares its
  assignment-operator logic with `SetVariable`(121)/`SetVariableEx`(124),
  including a real `PlusEquals` string-concatenation case. Cross-confirmed
  against the wolfrpg-map-parser crate's own `db_management_command` and
  the sample game's own real data, down to a stale editor-autofilled label
  the numeric-only implementation tolerates fine. Along the way, fixed a
  real crash in `VarStore#number`/`#string`: a self-variable bank slot
  whose last write and next read disagree on type (reachable any time a
  project reuses a self-var for a different purpose across separate common
  event invocations) is now coerced defensively instead of crashing.
  XY-array addressing, name↔index lookups, data reset/insert/extract/copy/
  sort, and CSV import/export (`ImportDatabase`(251)) remain unimplemented.
  See `docs/adr/0075-wolf-rpg-editor-database-command.md`.
