# 37. A spell you can see

Date: 2026-08-06

## Status

Accepted

## Context

`scripts/rpg2k_field_audit.rb` ranks the database fields the real games set that
the runtime never reads, and `animation_id` sat at the top of it by a wide
margin. The full picture is stronger than the audit's own count:

| | animations in the table | skills naming one | items naming one |
|---|---|---|---|
| Nepheshel | 500 | **306 of 306** | **1200 of 1200** |
| mtf-meido-action | 150 | **134 of 134** | **100 of 100** |

Every skill and every item in both games names a battle animation, and every one
of those ids resolves to a real row. None of them played. A fight was a status
panel, a line of text and an HP number going down.

The machinery to draw one already existed and had exactly one caller. The map's
Show Battle Animation event command (11210) drives a frame-by-frame player —
`start_map_animation` / `step_map_animation` / `draw_map_animation` /
`blit_animation_cell` / `fire_animation_flashes`, compositing into a
screen-sized `@animation_sprite` at z 150. The battle screen renders through the
same `Scene::Map#render`, and its battler sprites sit at z 100+, so an animation
was already going to land in front of them. What was missing was a way to ask
for one that was not an event command.

## Decision

Split the player from its one caller, and let a battle round drive it.

- **`build_animation(id, tx, ty, battle = false)`** is the player, taking an
  explicit animation id and target pixel. `start_map_animation` becomes a thin
  wrapper that reads the interpreter's request and resolves a map character's
  pixel; the battle path passes an id off a database row and a screen pixel.
- **`battle` means two things**, and they are the only two differences between
  the cases. The pixel is already a screen position rather than a map one, so
  `draw_map_animation` skips the camera subtraction; and nothing is waiting on
  the animation to finish, so `step_map_animation` skips `@interpreter.resume`.
  A battle animation has no paused event behind it.
- **The animation is on the skill and on the item**, not on the action:
  `battle_animation_id` reads the row the log entry's `skill_id` / `item_id`
  names. That plumbing was already there — the skill id went onto the entry for
  the battle-log sentences (ADR 0036).
- **The round is paced by the animation** when there is one. `drive_battle_animate`
  steps it to completion before landing the next action, in place of the fixed
  `BATTLE_ANIM_FRAMES` banner timer; an action with no animation keeps the timer
  exactly as before.
- **Where it plays.** Over the targeted enemy's sprite, centred — the entry
  carries the target's index into the enemy list, so the sprite is found without
  matching on a name two monsters can share. RPG2000's battle is first-person and
  draws no sprite for a party member, so an action aimed at one plays over the
  middle of the screen rather than nowhere.

## Consequences

Every skill and item in both test beds now shows the animation its author picked
— which is most of what a fight looks like, and all of it was already in the
`.ldb`.

Deliberately not in this change:

- **A plain attack's animation.** RPG2000 takes it from the equipped weapon, and
  the log entry does not carry the weapon. Plumbing that through is a change of
  its own; guessing an id here would put the wrong animation on every swing.
- **`position`** (whole screen / target / above / below) is carried on the
  player but not yet acted on: every animation is drawn centred on its target
  pixel, which is `position` 1. Both test beds set the field, so this is a real
  gap rather than an absent one, and it wants its own before/after.
- **Per-cell tone and scale.** The cell blit copies the 96x96 chip straight
  across; RPG2000's own renderer tints and scales each cell from the frame's
  cell record. The map path has always had this limit and this change does not
  widen it.

Covered by `scripts/rpg2k_scene_check.rb` (a skill that names an animation arms
the player and centres it on the enemy sprite; one that names none arms nothing;
an action on a party member centres on the screen; the round is held until the
animation finishes and no interpreter is resumed; an item resolves its id the
same way a skill does, and a plain attack resolves none; and a battle animation
draws from its own pixel with the camera 500 tiles away) and by
`scripts/rpg2k_testbed_logic_check.rb`, which asserts against the **real** tables
that every animation id every skill and item names is a row the database really
has, and that the animation table carries drawable frames at all.
