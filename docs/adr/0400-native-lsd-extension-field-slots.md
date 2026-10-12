# 0400. Decode native LSD slots for extension-backed state

Date: 2026-10-11

## Status

Accepted.

## Context

ADR 0395 put several state values in project-specific chunk 200. Some have
standard LSD slots that the schema did not expose. A shared `SAVE_MOVABLE`
layout also assigned field 101 to the vehicle type for every chunk, although
hero chunk 104 uses it as a boarding flag. Field 108 similarly means a menu
request on the hero and parallel execution state on a map event.

The primary reference is [liblcf's field table](https://github.com/EasyRPG/liblcf/blob/master/generator/csv/fields.csv),
with pan defaults from [SavePartyLocation](https://github.com/EasyRPG/liblcf/blob/master/src/generated/lcf/rpg/savepartylocation.h).
The native verification below uses Nepheshel's genuine RPG Maker 2000
`RPG_RT.exe` under Wine staging 11.8, with a Japanese locale and Xvfb's
640×480 16-bit display. It does not use EasyRPG Player.

## Decision

Expose weather in `SAVE_SCREEN`, and give hero chunk 104 its own lazily built
`SAVE_PARTY_LOCATION` schema. It inherits the movable fields but overrides
conflicting ids and adds boarding, pan and encounter fields. Vehicle and map
event records retain their existing schemas. The packed-schema generator
resolves the new table normally; no runtime dependency is added.

This change exposes the native wire fields. Migrating `Game::State` export and
restore away from chunk 200 is a separate change, requiring coordinate and
precision conversions plus backward compatibility with existing engine saves.

| State | Native path (decimal ids) | Type / units |
| --- | --- | --- |
| Weather / strength | 102 / 48, 49 | integers |
| Boarding / aboard / vehicle / unboarding | 104 / 101–104 | bool, bool, int, bool |
| Preboarding speed | 104 / 105 | integer, default 4 |
| Menu request | 104 / 108 | bool |
| Pan follow state | 104 / 111 | 0 fixed, 1 following |
| Pan current x/y | 104 / 112, 113 | integer, sixteenths of pixels |
| Pan target x/y | 104 / 114, 115 | integer, sixteenths of pixels |
| Pan speed | 104 / 121 | integer, sixteenths of pixels/frame |
| Encounter accumulator | 104 / 124 | integer |
| Player flash RGB / current level / frames left | 104 / 81–85 | int, int, int, double, int |
| Common-event cursor | 114 / event id / 1 / 1 / frame id / 11 | integer inside an execution stack |
| Current / target picture transparency | 103 / picture id / 8, 34 | double / integer |

Pan defaults are x=2304, y=1792, speed=16. Rightward camera movement subtracts
from the hero-relative x coordinate; downward movement subtracts from y. These
are not the zero-based pixel offsets used by `Game::Screen`. Chunk 102's 41/42
also exist, but are not substitutes for the hero's complete pan state.

Picture fields were already correctly declared double/integer in the schema.
The unnecessary rounding of current transparency is in the runtime writer,
not a schema type bug. Arbitrary fractional target opacity, original flash
peak power/duration and an erased picture's remembered name still have no
identified exact native representation.

## Native captures

The executable SHA-256 is
`6b68febc0c3d91b7a997a89c05c3e761494c2d800b6cebcd980b7ce98c3f164c`.
All game edits and Wine runs used an isolated copy; original game data was
preserved. The probe replaces the loaded map's events with one autorun event
that executes the commands below and opens the genuine Save menu (11910).
The menu freezes the scene, allowing in-flight state to be captured.

- **Rain, locked pan and player flash:** Weather `[1,2]`; Pan lock `[0]`;
  Pan right four tiles `[2,1,4,1,0]`; Flash Sprite
  `[10001,31,7,3,25,100,0]`; Open Save. Native bytes give weather=1,
  strength=2, pan_state=0, pan target x=1280, speed=4, and flash
  RGB=31/7/3, level=25.0, remaining=600. Current x/y and target y were
  omitted at their defaults. Target x is 2304−4×16×16.
- **Snow, completed pan, airship and moving picture:** Weather `[2,1]`;
  Pan down three tiles with wait `[2,2,3,2,1]`; Set Airship Location;
  Enter Vehicle; Wait 30 tenths; Show Picture with transparency 17;
  Move Picture toward transparency 63 over 100 tenths; Wait one tenth;
  Open Save. Native bytes give aboard=true, vehicle=3, current/target
  pan y=1024 (1792−3×16×16), pan speed=8, current picture transparency
  17.460000000000008, integer target=63 and remaining=594.
- **Encounter accumulator and parallel common event:** Seed hero field 124
  with BER 12345, preserving the parent chunk after editing. A parallel
  common event runs Weather `[1,1]`, Wait `[100]`, End while the foreground
  opens Save. Native re-save retains 12345. The common-event frame contains
  those three commands, current_command=2, event_id=0 and wait_time=599.
  This verifies preservation of the accumulator, not its terrain increment
  formula. The captured common-event id was 505.
- **Immediate airship boarding followed by Open Save:** RPG_RT already reports
  aboard=true and vehicle=3; the boarding/unboarding flags are absent. The
  true transition flags, preboarding speed and menu-request flag are
  source-defined, but their non-default values were not captured.

The reduced native bytes for weather, pan, flash, aboard state, encounter
accumulator, picture transparency and common-event execution are embedded in
`mruby-lcf/test/lcf_test.rb`. They are copied from RPG_RT output, not generated
by this project's encoder.

### Reproducing

`scripts/lcf/native_schema_probe.rb` prepares a fresh isolated game copy:

```sh
ruby scripts/lcf/native_schema_probe.rb \
  data/Nepheshel206beta/Nepheshel206Nbeta /tmp/lsd-screen screen
```

Other scenarios are `vehicle-picture`, `encounter-common` and `boarding`.
Each output directory must be new. The helper leaves only slot 1, removes
saved foreground/common-event state and replaces map events. The common-event
scenario appends a new database common event and prints its id.

Run `RPG_RT.exe` from that directory with Wine and the Japanese locale. Wait
for the title screen, select Continue, and load slot 1. The probe opens the
Save menu; save into slot 2 so the input remains available. The vehicle/picture
scenario takes several seconds before opening Save. Read `Save02.lsd` with
`LCF::SaveData`; inspect the paths in the table above. Always assign a changed
nested row back to its parent before writing: decoded children are cached
views, and modifying one does not replace the parent's original raw payload.

### Limits and other findings

The earlier load test compared original, engine export without chunk 200,
engine export with chunk 200, and original plus chunk 200. All four loaded to
pixel-identical map screenshots in this executable. This establishes load
acceptance, not retention of unknown fields after a native re-save, and is not
an RPG2003 compatibility claim.

A full recursive schema walk of the new native saves exposes an existing
chunk-113 mismatch: RPG_RT stores `SaveEventExecState` directly there, whereas
our `SAVE_FOREGROUND_EVENT` adds an `execution_state` wrapper. The screen
capture consequently fails the old walker in a spurious second frame. The
common-event wrapper in chunk 114 is correct. Fixing foreground export and
restore together, with compatibility for existing wrapped engine saves, is
separate work; the confirmed field tests do not depend on chunk 113.

## Consequences

Native saves can expose weather, boarding state, complete hero camera state
and encounter accumulation through named fields. Hero field 101 is no longer
misread as a vehicle id, and field 108 no longer uses a nested-event type.
Existing extension-backed engine saves keep their existing save policy.
RPG2003-specific fields and native transition flags need further captures.
