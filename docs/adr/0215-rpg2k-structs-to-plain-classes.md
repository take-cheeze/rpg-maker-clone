# 0215. mruby-rpg2k records are plain classes, not Structs

Date: 2026-09-23

## Status

Accepted

## Context

mruby-rpg2k/mrblib defined 17 records with `Struct.new`: Scene::Map's
`MapEventState` (read and written for every event every frame),
`MessageState`, `ShopState` and `ShopQuantity`; `Game::Battle::Combatant`;
the interpreter's `NameInputRequest`, `InnRequest`, `ShopRequest`,
`BattleRequest`, `KeyInputRequest`, `KeyInputAccepted` and
`DiagnosticPosition`; `Game::CommonEvent::CommonEventRecord`; and the
message scanner's `Segment`, `SpeedMarker`, `PauseMarker` and `ScanResult`.
Most accesses were `x[:member]`, left over from when the records were Hashes.

bc2cpp cannot do much with a Struct:

- A Struct member is a boxed `mrb_value` in an RArray.
- Its accessors are native closures that `Struct.new` creates at run time, so
  a call site cannot be devirtualized into them. They were the 998
  `unknown_definer` sites in ADR 0210's closed-world summary.
- `x[:member]` is a `[]` send that bc2cpp does not model at all.

A plain class's ivars can live in the object's RData struct as typed fields
(ADR 0205): an Integer is an unboxed `mrb_int`, a boolean an `mrb_bool`, a
Symbol an `mrb_sym`. A call site guards on the class and then loads the field
directly.

## Decision

Each record is a plain class with `attr_accessor`s and an explicit
`#initialize`. Every literal `x[:member]` / `x[:member] = v` on a record
becomes `x.member` / `x.member = v`: 598 sites in mrblib and 418 in the host
harnesses. The Struct behaviour that code actually used was found by reading
each receiver's origin, and by a CRuby run of every host harness with the
Struct methods traced (`[]`, `[]=`, `==`, `eql?`, `hash`, `to_h`, `to_a`,
`members`, `each`, `each_pair`, `values`, `dig`, `inspect`, `to_s`, `dup`,
`clone`, `is_a?(Struct)`, `Struct ===`, and every object reaching
`Marshal.dump`). Only this was in use, and it is kept:

- **Construction.** Every runtime site already built its record with a bare
  `.new` followed by one setter per field, so `#initialize` takes no
  arguments. `Combatant` is the exception. `Battle.from_actor`/`.from_enemy`
  pass 22 positional values and the fixtures pass 6, so its `#initialize`
  takes those 22 as optional positional parameters. Keyword construction was
  used only by one logic-check helper, which now builds the records with
  setters.
- **Initial values.** A Struct member starts nil. A field that every
  construction site sets right after `.new` gets a typed default instead (0,
  `false`, or a Symbol), and nothing reads it before the site overwrites it.
  That typed `SETIV` is what lets bc2cpp embed the field. A field that some
  site leaves unset keeps its nil start. Examples of nil fields are
  `MapEventState`'s `flash`, `forced_route`, `forced_freq` and
  `crossed_hero_this_frame`, and `BattleRequest`'s `background` and `random`.
- **Computed keys.** `KeyInputAccepted` was the only record read with a key
  computed at run time (`acc[group]`, `accepted[sym]`). It gets a `case`-based
  lookup that raises Struct's `NameError` ("no member 'x' in struct") for an
  unknown symbol. The lookup is named `#accepts?`, not `#[]`: bc2cpp adds
  every class that defines `#[]` to the guard chain of every `[]` call it
  cannot type, which is 1,488 sites in mruby-rpg2k-compiled. Naming it `#[]`
  cost 70,067 bytes of `-Os` text over `#accepts?`.
- **Readers that override a member.** `Combatant#atk_states`, `#row` and
  `#gauge` read `self[:x]` with a default. They now read `@x`, and those three
  fields get an `attr_writer` only.
- **Equality.** No runtime `==`, `index`, `include?` or `delete` on a record
  ever compared two distinct objects equal. The only value comparisons were
  in `rpg2k_logic_check.rb`'s expected segments. That check now compares
  field values through a `record_values` helper.
- **Unused.** `hash`/`eql?`, `to_h`/`to_a`, `members`, `each`, `dig`, `dup`
  and `clone` at run time, `inspect`, `is_a?(Struct)` and Marshal were never
  used. The only `dup` of a record was a `Combatant` in
  `rpg2k3_battle_row_check.rb`, under CRuby.

Sixteen of the classes join mruby-rpg2k-compiled's owners and
`BC2CPP_WIRED_EMBEDDINGS` (tools/bc2cpp/compiled_gems.rb). `Combatant` was
already an owner. It is not wired, because none of its fields has a typed
`SETIV`: every value is a constructor argument or a later write.

## Consequences

bc2cpp embeds these fields (the `*_ivars` structs in the generated code):

| class | embedded fields |
| --- | --- |
| MapEventState | `mrb_int` id, move_type, move_timer, layer, anim_type, base_pattern, anim_phase, anim_count, disp_x, disp_y, move_count, slide_frac; `mrb_bool` guarded, overlap_forbidden, translucent, moving, jumping |
| MessageState | `mrb_int` count, choice_start, inner_w, page, pages, face_x, face_y, text_x, text_w |
| ShopState | `mrb_int` index, scroll, cmd_index |
| ShopQuantity | `mrb_int` id, count, max; `mrb_sym` mode |
| NameInputRequest | `mrb_int` actor_id, charset |
| InnRequest | `mrb_int` type, price; `mrb_bool` can_afford, prompt |
| ShopRequest | `mrb_int` mode, type; `mrb_bool` allow_buy, allow_sell |
| BattleRequest | `mrb_bool` allow_escape, defeat_game_over |
| KeyInputRequest | `mrb_bool` wait |
| KeyInputAccepted | `mrb_bool` all nine flags |
| DiagnosticPosition | `mrb_int` index, size, call_depth |
| CommonEventRecord | `mrb_int` id |
| Segment | `mrb_int` color |
| SpeedMarker | `mrb_int` at, speed |
| PauseMarker | `mrb_int` at; `mrb_sym` kind |
| ScanResult | `mrb_int` length, end_color; `mrb_bool` auto_close, show_gold |

Object-valued fields (`char`, `route`, `window`, ...) stay in `iv_tbl`. Their
call sites still devirtualize to a guarded `mrb_iv_get`. In the generated
code, 2,076 call-site notes name one of the 17 classes. Of those, 190
accessor sites load an embedded field and 279 go through `iv_tbl`.

Measured against origin/master in a Release `RPGMAKER_BC2CPP=1` build, under
`valgrind --tool=callgrind --collect-atstart=no
--toggle-collect='RPG2k_main_loop_impl*'`. `RPG2k#main_loop` runs once per
frame, so its call count is the frame count and boot is excluded. There is no
fixed-frame option, so the runs used `--no_render_wait` with a wall-clock
`--timeout_ms`, and the table compares per-frame figures:

| scenario | | master | branch | change |
| --- | --- | ---: | ---: | ---: |
| Nepheshel map 114, 258 events (`--rpg2k_preview_map=114`, 900 s) | frames | 1,419 | 1,641 | |
| | Ir/frame | 76,539,666 | 67,979,366 | -11.2% |
| | Ir/frame without libSDL2/libfluidsynth | 69,717,871 | 61,278,438 | -12.1% |
| | Ir per `Scene::Map#update` | 65,912,160 | 57,919,633 | -12.1% |
| troop 1 (`--rpg2k_battle_troop=1 --rpg2k_battle_play`, 600 s) | frames | 4,478 | 4,466 | |
| | Ir/frame | 10,902,460 | 10,925,077 | +0.2% |
| | Ir/frame without libSDL2/libfluidsynth | 3,922,442 | 3,926,412 | +0.1% |
| | Ir per `Scene::Battle#update` (240 calls each) | 2,967,804 | 2,980,946 | +0.4% |

The battle is neutral. `Combatant` has no embedded fields, and each battle
builds its combatants once.

The `-Os` text of mruby-rpg2k-compiled's `register.o` falls from 4,750,480 to
4,604,188 bytes (-146,292, -3.1%). The measurement compiled the generated
`register.cxx` with the build's own flags plus `-Os` (the gem sets no `-O`
level of its own).

The closed-world run (`BC2CPP_CLOSED_WORLD=1`, the wio gem set) now reports:

| KEPT reason | master | branch |
| --- | ---: | ---: |
| method_missing_receiver | 1,939 | 3,186 |
| unknown_definer | 998 | 0 |
| core_or_native | 986 | 1,375 |
| unlisted_class | 498 | 907 |
| opaque_definer | 325 | 236 |
| singleton_definer | 135 | 146 |
| dynamic_install | 41 | 41 |
| total kept | 4,922 | 5,891 |

Guards dropped went from 1,724 to 1,718, and `bc2cpp_send` sites from 17,861
to 17,827. The kept total grows because about 600 `x[:member]` sites used to
be `[]` sends outside the closed-world model. They are now named sends that
the model counts. Most of them keep their dispatch as
`method_missing_receiver`, because LCF defines `method_missing` and their
receiver is not `self`. They will convert once LCF's `method_missing` is
removed. Some accessor names are also core method names (`max`, `count`,
`index`, `at`, `size`), so those sites count as `core_or_native`.

Behaviour differences:

- **Identity equality.** Two `Combatant`s built from the same enemy row with
  the same HP used to compare equal as Structs. Now they compare by identity.
  `@enemies.index(target)` (a battle log entry's `target_index`, used to
  place the attack animation and the target flash) and the RPG2003 ready-order
  tie-break (`@enemies.index(c)`) used to answer the first twin's slot for
  the second twin. They now answer the target's own slot. The
  `target_enemy_index` and `turn_order` comments already treated that
  collision as a hazard to avoid. No harness or game run reached it.
- **Typed writers.** In a bc2cpp build, the attr_writer of an embedded field
  raises `TypeError` for a value of another type (ADR 0205's synthesized
  accessor). A CRuby run of every host harness, with each typed writer
  checked, saw no mistyped write.
- **Embedded instances are RData.** In a bc2cpp build, instances of the 16
  wired classes are `MRB_TT_DATA`. As ADR 0193 notes, `dup`/`clone` of such
  an object copies no fields, and mruby-marshal cannot dump one. No code
  dups, clones or marshals a record today. New code must not start to.
