# 82. WOLF RPG Editor LoadVariable(221)/SaveVariable(222)

Date: 2026-09-07

## Status

Accepted

## Context

WolfTL's own `Command.hpp` names codes 220-222 `SaveLoad`/`LoadGame`/
`SaveGame`, but those last two names are misleading: help/04ev_file.html's
own "セーブ・ロード操作" page documents three genuinely different
operations, and only 220 ("保存・読込（セーブ/ロード）") is a *whole-game*
save/load -- it needs to serialize this reader's entire running state (every
variable/switch/database/map/event position), a format this reader does not
have at all, and is left unimplemented (falls through to the interpreter's
default case), the same "no foundation yet" reasoning `Party`(270) is
already documented under.

221/222 ("セーブデータからの読み込み (変数・文字列)"/"セーブデータへの書
き込み") are much smaller: each touches exactly *one* variable or string at
a time, reading/writing it into a small per-save-slot blob at
`Save/SaveDataNN.sav` -- independent of, and much smaller than, a real save.
The wolfrpg-map-parser crate's own `save_load_command` module confirms this
split precisely: its `Base` struct (`operation` Save/Load + `save_number`,
matching 220's own 2-argument real calls) is a *separate* struct from its
`LoadVariable`/`SaveVariable` (both `parse_variable_fields`'s own `(var1,
save_number, var2, is_pointer)` shape, matching every one of 221's 9 and
222's 2 real calls' own 4-argument shape exactly).

`arg(0)`/`arg(2)` are the live-game variable and the save file's own key
(both raw WOLF value-ref ids, `Wolf::VarStore#number`/`#string`-decodable);
`arg(1)` is the save number, and `arg(3)` is `is_pointer`. Real data resolves
`arg(1)` two ways, both confirmed by the manual's own "特殊機能　保存ファイ
ル名を文字列変数で指定" section: a plain numeric ref names
`Save/SaveDataNN.sav`, while a *string*-typed ref (real calls use this
common event's own self-variable "string quintet," 1600005-1600008, not just
the literal 3000000+ range the manual's own example happens to use) names
the file directly, verbatim, relative to the project root -- which is why
`VarStore` gained a new `#string_ref?` predicate (mirroring `#number`/
`#string`'s own kind dispatch) rather than checking `ValueRef.decode`'s kind
by hand in two different places.

`arg(2)`'s own system variable 24 (help/06systemvalue.html's own
"[読]ｾｰﾌﾞﾃﾞｰﾀ読込判定(1=成功 0=失敗)") is special-cased in
`#exec_load_variable` to the save file's own existence, overriding whatever
(if anything) is actually stored under that key -- confirmed by real data:
CE#94's own save/load screen renderer reads it first, immediately before
system variable 29 (play time), a plausible per-slot existence-then-preview
pair.

`is_pointer` (`arg(3)`) is true in roughly half of this sample game's own
real `LoadVariable` calls (CE#94 again), but the crate is the *only* source
for this field at all -- no manual page documents it, and this reader found
no way to cross-check a guessed meaning (a further indirection through
`arg(2)`'s own current value, the only reading that fits the name) against
real data. Left unimplemented rather than guessed, the same "no independent
source" reasoning `BanInput`(126) is already documented under.

## Decision

- A new `Wolf::SaveData` module (`mruby-wolf/mrblib/save_data.rb`) resolves
  a save number/string ref to a real file path (`.path_for`, rejecting an
  unsafe string name per the manual's own documented Ver3.00+ restriction)
  and reads/writes a flat `{raw_id => value}` Hash to it via `Marshal`
  (`.read`/`.write`) -- not WOLF's own real `.sav` format (which also
  carries a full 可変DB snapshot, XY arrays and more this deliberately small
  blob does not attempt), but the same "serialize a plain Ruby value
  straight to a project-relative file" pattern `mruby-rpg2k`'s own
  `#save_game`/`#load_save_state` and `mruby-rpgxp`'s own `RGSSData#save_
  object`/`#read_object` already use elsewhere in this codebase.
- `Wolf::Interpreter#exec_load_variable`/`#exec_save_variable` gate on the
  real 4-argument shape and `is_pointer == 0`, then read/write through
  `Wolf::SaveData` and `VarStore#number`/`#string`/`#string_ref?` -- a
  missing save file, or a key never written into an existing one, reads
  back as 0/`""`, the manual's own documented default.
- `mruby-wolf/mrbgem.rake` gained `add_dependency 'mruby-dir'`/`'mruby-
  marshal'`/`'mruby-enum-ext'` (all three already in `build_config.rb`'s
  shared gem list, but declared here too so the per-gem test build has them
  -- see `mruby-sprintf`'s own existing comment on this exact trap) and
  `save_data.rb` was added to `spec.rbfiles`'s explicit load order, after
  `vars.rb` (needs `VarStore#string_ref?`) and before `interpreter.rb`
  (calls `Wolf::SaveData` directly).

## Consequences

- `LoadVariable`(221)/`SaveVariable`(222) now read/write real save-slot
  files -- verified by five new tests (a real round trip through an actual
  file, the missing-file/-key 0/`""` default, the system-variable-24
  existence special case, the string-named-file mode including the unsafe-
  name rejection, and the `is_pointer`/argument-count gates), the CRuby
  harness (116 assertions, 0 failed), `ctest -R mruby_test` (crash count
  held at the pre-existing 19-crash baseline once `mruby-enum-ext` was
  declared -- `Array#none?` is otherwise silently missing from the per-gem
  test build even though `build_config.rb`'s shared list already carries
  it, the exact trap `AGENTS.md`'s own "mruby stdlib methods live in core
  `*-ext` mrbgems" section describes), `scripts/wolf_testbed_check.rb`,
  `scripts/wolf_interpreter_check.rb` (which needed `save_data.rb` added to
  its own `load` list -- it hit a real `NameError: uninitialized constant
  Wolf::SaveData` on this exact sample game's own real 221/222 calls before
  that fix), and the compiled binary against the real sample game.
- Still unimplemented: `220` itself (the whole-game save/load), `is_pointer`
  indirection, and every other save/load-adjacent surface (可変DB/XY-array
  persistence inside a real save, `ImportDatabase`(251)'s own CSV path).
