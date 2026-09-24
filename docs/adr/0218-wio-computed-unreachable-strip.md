# 0218. Wio: strip the Ruby methods nothing can call, computed at build time

Date: 2026-09-24

## Status

Accepted

## Context

The default `wio_rgss_boot` firmware overflows the Wio Terminal's 507,904-byte
flash by about 624 KB. mruby-rpg2k's bytecode alone is 362 KB of it. mruby
loads a gem's whole mrblib as one irep blob, so `--gc-sections` cannot drop a
method nothing calls. Only removing the `def` from the source mrbc compiles
does that.

The wio build already rewrites mrblib copies by hand: `$stderr` output
(ADR 0119), single-caller helpers (ADR 0129), dead RGSS features (ADR 0132),
and bc2cpp stubs (ADR 0144). A first name-based pass over the flash analysis
(`deadmeth.rb`) estimated 11 KB in the engine gems. It worked on bytecode
symbols, though, with no call graph and no rule for what dispatches without
a call site.

Three facts make a sound analysis possible:

- The closed-world lint (ADR 0212) keeps dynamic dispatch out of mruby-rpg2k,
  mruby-lcf and mruby-rgss.
- LCF no longer answers fields through `method_missing` (ADR 0213).
- ADR 0210 lists the sources that share a closed-world build's VM
  (`bc2cpp_closed_world_outside_srcs`).

## Decision

`scripts/wio_unreachable_methods.rb` computes the unreachable methods, and
`scripts/strip_wio_unreachable_methods.rb` deletes them from the wio build's
mrblib copies. `build_config.rb`'s `wio_strip_unreachable` runs both, after
every other rbfiles filter. It is called from the three gems' `mrbgem.rake`.

### The analysis

The world is the wio build's own rbfiles for the three gems, after the
earlier rewrites. Everything else sharing the VM comes from ADR 0210's list:
mruby core and every other gem's mrblib and C sources, `include/`, and the
host sources in `app/wio/src`. The host sources are where the entry points
(`RPG2k.new`, `main_loop`, `current_scene_name`) live. In the build, the gem
list comes from the build itself.

Code is split into units: everything outside a `def` (class bodies,
top-level, constants) runs when the file loads, and each `def` is a unit
keyed by its name. A worklist starts from:

- every outside-`def` unit;
- the VM and core hooks (`initialize`, `to_s`, `hash`, `<=>` and every other
  operator, `method_missing`, `coerce`, `marshal_load`, ...);
- every name native code can dispatch.

When a name becomes live, every `def` of that name is scanned. A `def` whose
name never becomes live is unreachable. A unit counts these as live names:

- **Call sites.** Every Prism call node, including `&:m`, `a.x ||=`, `a.x +=`
  and multiple-assignment targets; `for` counts as `each`.
- **Literals.**
  - Every Symbol literal; this covers `respond_to?(:m)`, `alias`, and the
    names a reviewed computed `send` draws from.
  - Every identifier-shaped token of a String literal. A string holding
    control bytes, such as the LCF schema blob that `to_sym`s its names, is
    matched by substring instead.
  - An interpolated Symbol, or an interpolated String with static text,
    counts as a pattern. `:"#{type}_x"` keeps every def name ending in `_x`.
- **Native code.** Every C string literal and `MRB_SYM`-family token, except
  those that only name a method in `mrb_define_method` or `MRB_MT_ENTRY`: a
  definition dispatches nothing. `@ivar`/`$gvar` spellings are skipped.
- **Not references.** Arguments of `attr_*` define accessors and call
  nothing. Arguments of a class body's
  `private`/`protected`/`public`/`module_function` list don't count when the
  owner `def`s that name, because the strip rewrites the list. A list naming
  an inherited, native or attr method keeps that name live.

`super` needs no rule. It dispatches the enclosing method's own name, which is
already live whenever that body can run.

### Soundness

Name granularity over-approximates every receiver. So a method is only called
unreachable when no reachable code can spell its name anywhere. The gaps are
names built at run time.

The analysis flags each world site that dispatches a non-literal name:

- `send`, `respond_to?`, `method` and similar with a variable name;
- `to_sym`;
- a `method_missing` or `respond_to_missing?` definition.

Each flagged site must be listed in `WioUnreachable::REVIEWED`, with the
literals its names come from; otherwise the analysis, and so the wio build,
fails. The closed-world lint keeps new sites rare. Today there are ten:

- LCF's `field?`;
- the error-report `Tee` forwarding call-site names to its IO;
- `modified_stat` and the equip menu's `STAT_DEFS`;
- the schema blob's `to_sym`.

A further six are in `game/battle.rb`, which is desktop-only.

What stays outside the analysis:

- It is off under `RPGMAKER_BC2CPP`. The compiled C++ calls methods by the
  original source, not the rewritten copy.
- `current_scene_name` is kept because the maix game main in `app/wio/src`
  calls it; wio's own boot firmware does not.
- The desktop-only probes that `src/main.cxx` calls behind dev flags
  (`audio_probe`, `effect_probe`, ...) are stripped, since `src/` is not in
  the wio build.

### The strip

`strip_wio_bc2cpp_stubs.rb`'s AST-based deletion is factored into
`strip_defs_from_source`, and both strips use it. For this strip, a stripped
name also leaves its owner's `private`/`public`/`module_function` lists
wherever they are in the closed world, including a list's trailing name (the
#1914 bug). A one-line `def` may now end with a trailing comment.

The list is computed at build time. A shared rake task writes
`unreachable.tsv` once per build, from a manifest of the real file lists, and
takes about 5 s. It fails if `WIO_GEMS`, the gem list the checked-in mode
assumes, no longer matches the build. `RPGMAKER_WIO_KEEP_UNREACHABLE=1` turns
the strip off, for measuring or bisecting. `RPGMAKER_WIO_UNREACHABLE_HOST=1`
forces it onto the desktop build for testing only; desktop game Ruby (RGSS
scripts) is outside what the analysis sees.

### Checks

- **`scripts/wio_unreachable_methods_check.rb` (CI).** A fixture world has a
  method reachable only through each of: `&:sym`, `super`, native
  `mrb_funcall`, a `respond_to?` guard, a String literal, a binary blob, an
  interpolated Symbol, outside Ruby, and a VM hook. It also has seven
  unreachable ones:
  - a truly dead method;
  - a dead-only chain;
  - a name native code only defines;
  - a singleton method;
  - a `module_function`;
  - two members of a mixed `private` list.

  It asserts exactly those seven are stripped, then runs the stripped fixture
  under CRuby. It also asserts an unreviewed computed `send` fails the
  analysis. Disabling any single rule makes it fail, checked for all ten
  rules.
- **`scripts/wio_strip_scripts_check.rb` (CI).** It now also runs the analysis
  on the wio rbfiles, which it gets by evaluating each `mrbgem.rake` as the wio
  build does, and requires every strip to apply and parse. CI has no
  submodules, which only makes it strip more (119 there, 118 with `3rd/`).

## Measured result

A real `pio run -e wio_rgss_boot` link (arm-none-eabi GCC 14.2.1, default
configuration), with the strip off (`RPGMAKER_WIO_KEEP_UNREACHABLE=1`) and on:

| | strip off | strip on | Δ |
| --- | ---: | ---: | ---: |
| ld FLASH overflow | 624,164 | 602,028 | **−22,136** |
| flash image incl. `.data` | 1,145,091 | 1,122,219 | −22,872 |
| bytecode: mruby-rpg2k | 362,542 | 350,611 | −11,931 |
| bytecode: mruby-rgss | 25,325 | 17,591 | −7,734 |
| bytecode: mruby-lcf | 37,761 | 37,236 | −525 |
| symbol table (presym) | 81,494 | 78,988 | −2,506 |
| static RAM | 32,296 | 31,560 | −736 |

118 defs (117 names) go, out of 1,655 in the wio world. The per-method bytes
below come from the `mrbc -v` irep cost model (`--mrbc`), which sums to
20,345 against 20,190 measured.

| file | defs | bytes | methods |
| --- | ---: | ---: | --- |
| `lcf/lcf.rb` | 5 | 438 | `StringIO`: ungetbyte 100; `LCF`: var_max 86, var_min 86, pc_hp_max 82, npc_hp_max 84 |
| `rgss/error_report.rb` | 5 | 455 | `RGSS::ErrorReport::Tee`: print 169; `RGSS::ErrorReport.singleton`: install 95, installed? 61, probe! 61, probe_raise 69 |
| `rgss/lib.rb` | 37 | 7315 | `RGSS.singleton`: effect_probe 1157, transition_shape_probe 450, window_probe 446, windowskin_rect_probe 970, tilemap_above_layer_probe 256, probe_wav 476, audio_probe 950, wait_for_bgm_pos 131; `RGSS::Bitmap`: font= 64; `RGSS::Plane`: blend_type 67; `RGSS::Sprite`: ox 67, oy 67, angle 67, mirror 67, blend_type 67, src_rect 91; `RGSS::Tilemap`: autotiles 85; `RGSS::Window`: back_opacity 77, cursor_rect 91, pause 67, openness 77, open? 66, close? 68, padding_bottom 81, arrows_visible 76; `RGSS::Audio.singleton`: bgs_play 235, bgs_stop 61, bgs_fade 65, bgs_pos 61, me_play 153, me_stop 61, me_fade 65, midi_available? 61, setup_midi 147; `RGSS::Graphics.singleton`: resize_screen 71; `RGSS::Input.singleton`: dir8 186, mouse_pressed? 68 |
| `rpg2k/game.rb` | 58 | 10048 | `Game::Message.singleton`: expand 153, parse 78; `Game::TextReveal`: visible_lines 219; `Game.singleton`: round_half_even 146, opacity_to_trans 85; `Game::Actor`: name_changed? 100, title_changed? 137, total_state_count 132, skills= 164, weapon_states 639, attack_hit_rate 360, dual_attack? 71, strike_count 250, weapon_attack_multiplier 198, equipped_weapons 332, swing_weapon_data 211, weapon_roll_data 674, strong_defence? 161, force_ai? 161, exp_to_next 106, crit_chance 69, weapon_crit_chance 188, weapon_crit_bonus 334, set_hp 127, atb_gauge 67, battle_commands_changed? 75, rename_skill? 110; `Game::Party`: actor_by_id 124, promote_to_leader 159, alternate_battle_layout? 139, death_handler_event 136, death_handler_teleport 178, item_battle_occasion? 92, item_field_only? 96, item_effective? 652, unsupported_field_skill? 117, skill_defence_term 173, skill_ignores_defence? 107, skill_effective? 541; `Game::Party.singleton`: normal_skill? 97; `Game::Map`: substituted? 96, set_lower 78, set_upper 78, set_tile 111; `Game::CommonEvent.singleton`: eligible 196; `Game::Transition.singleton`: block_grid 77; `Game::Screen`: fade_transition 61, erased? 66, tint_save_data 126, restore_tint 158; `Game::Picture`: finish_zoom 61, finish_opacity 61, finish_saturation 61, frames_left 61; `Game::Backdrop.singleton`: name_for 326; `Game::Vehicle`: load_movable 237; `Game::Timer`: display_text 165; `Game::State`: timer_display_text 71 |
| `rpg2k/interpreter.rb` | 1 | 234 | `Game::Interpreter`: start_death_handler 234 |
| `rpg2k/main.rb` | 2 | 151 | `RPG2k::Window`: opening? 83; `RPG2k`: map_scene 68 |
| `rpg2k/scene/equip_menu.rb` | 2 | 296 | `RPG2k::Scene::EquipMenu`: item_stat_sum 148, equip_delta 148 |
| `rpg2k/scene/map.rb` | 8 | 1408 | `RPG2k::Scene::Map`: current_map_tone 75, play_battle_bgm 143, play_victory_bgm 230, victory_bgm 405, restore_pre_battle_bgm 201, terrain_backdrop 76, backdrop_for_terrain_id 215, invalidate_tile_cache 63 |

Most of these are called only from files wio already excludes: battle (ADR
0107/0124), LSD interop (ADR 0128), the debug tools (ADR 0097), and desktop
`src/main.cxx`. The RGSS readers serve XP/VX scripts; wio's native code reads
their ivars directly.

Compared with `deadmeth.rb`'s 79 engine names, 67 are shared. It had 12 this
analysis keeps:

- 9 are substrings of the schema blob;
- `zoom_x`/`zoom_y` match `:"#{type}_x"`/`_y`;
- `current_scene_name` is the maix entry point.

This analysis finds 50 more:

- names only dead code calls (`weapon_roll_data`, `set_tile`, ...);
- names that native code only defines (`ox`, `src_rect`, ...);
- the desktop-only probes;
- call sites the earlier rewrites removed.

### Verification beyond CI

- **CRuby harness trace.** All 25 mrblib-loading harnesses ran on the original
  sources under a `TracePoint` recording every call to a method on the list.
  77 of the 118 were called (10,621 calls). Every call came from harness code,
  a wio-excluded file, another unreachable method, or a non-wio gem; none came
  from live wio-world code. Every harness passed as it does without the
  tracer.
- **Boot.** Booting the stripped firmware under Renode was not feasible: there
  is no Renode or .NET toolchain in this environment. `wio_rgss_boot` would
  only load the gems anyway, never the title. Instead, a desktop binary built
  with `RPGMAKER_WIO_UNREACHABLE_HOST=1` stripped the 45 defs its own world
  leaves unreachable (39 of them on the wio list), then booted Nepheshel
  through `--test_play` new game and battle.

## Consequences

- About 22 KB of flash is saved, with no hand-maintained list. A method a
  refactor strands is stripped on the next build. One that gains a caller
  comes back.
- A new computed-name dispatch in the closed world fails the wio build until
  it is reviewed. That is the price of soundness: the analysis cannot see the
  names such a site dispatches.
- Name granularity is conservative. One reachable `Sprite#x` keeps every
  `x`, and the schema blob keeps any name that is a substring of it (it costs
  `fadeout`, `stretch`, `finish_*`). A per-owner analysis, or decoding the
  blob's name table instead of matching substrings, would find more.
- Follow-ups:
  - run the same analysis over the core gems' mrblib (about 8 KB more, per the
    flash analysis);
  - make it work under `RPGMAKER_BC2CPP` by reading the compiled gem's
    symbol table as native source.
