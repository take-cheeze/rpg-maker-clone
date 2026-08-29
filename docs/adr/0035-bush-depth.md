# 35. Standing in the grass

Date: 2026-08-06

## Status

Accepted

## Context

RPG2000's 地形 row carries a `bush_depth` (field 11): how far a character
standing on that tile sinks into it. The bottom of the sprite goes
half-transparent, which is how the engine draws tall grass, shallow water and
waist-deep undergrowth — the character is *in* the tile rather than on it.

ADR 0034 fixed the terrain tag itself, so the row under a tile is now the row
RPG_RT means. `bush_depth` was the next field on it that nothing read.

Unlike the `damage` field beside it, this one the test bed genuinely uses.
Nepheshel names four of its terrains after the effect and lays two of them
across the shipped maps:

| terrain | `bush_depth` | tiles across the 543 shipped maps |
|---|---|---|
| #2 下半身3/1消去 ("erase the lower 1/3") | 1 | **5,192** |
| #3 下半身2/1消去 ("erase the lower 1/2") | 2 | **4,495** |
| #4 半透明表示 ("translucent") | 3 | 0 |
| #7 全身半透明 ("the whole body translucent") | 3 | 0 |

9,687 tiles across 28 maps. The names are the specification: the author wrote
down what each depth should do to the sprite, and the hero walked over all of it
fully opaque. (mtf-meido-action tags Forest and Snow: Forest at depth 1 but
places neither.)

## Decision

Read the field, following RPG_RT.

**The split.** RPG_RT stores the depth as a divisor's complement rather than a
fraction: `split = 4 - depth`, and a split above 3 means no effect, so only
depths 1..3 do anything — ported from a reference implementation's sprite-draw
arithmetic, not independently confirmed against genuine RPG_RT under wine.
The sunken height is `frame_height / split`, which on the standard 32px
charset frame is 10, 16 and 32 rows — exactly the thirds and halves
Nepheshel's names promise. `Game::CharSet.bush_pixels(depth, height = HEIGHT)`
is that arithmetic and nothing else, so it is a pure function the render check
can pin down.

**The opacity.** The sunken rows draw at `(opacity + 1) / 2` — half the top
opacity rather than a fixed 128, ported from a reference implementation's
bottom-opacity default and not independently confirmed against genuine
RPG_RT under wine. Halving rather than fixing matters for the one case where
it differs: an event already drawn translucent (a ghost, a Set Transparent
page) wading into grass ends up fainter still instead of snapping *up* to 128.

**The blit.** `Scene::Map#blt_bushed` lays a frame down as a solid top and a
half-opacity bottom, two blits from adjacent source rows. A depth of 0 is the
ordinary single blit and a depth that swallows the frame (`bush_depth` 3,
全身半透明) is a single blit at the sunken opacity, so neither degenerate case
pays for a split. Both the hero and the events go through it, and so does a
tile-graphic event — RPG_RT sinks the *sprite*, not a particular kind of
graphic, so that one scales its split against its own 16px frame rather than the
32px charset one.

**Who sinks.** The hero, unless jumping (they are over the tile, not in it) or
boarded (the vehicle sprite is drawn instead). An event only on the hero's own
layer — one drawn below or above is scenery or a treetop, not something standing
in the grass, matching the same-layer test a reference implementation makes too
(not independently confirmed against genuine RPG_RT under wine) — and not while
jumping. The hero's frame cache key gained the depth, so walking into and out of
grass redraws the sprite even though the pose has not changed.

## Consequences

9,687 tiles of Nepheshel now draw the hero the way its author labelled them.
Nothing else moves: a tile whose terrain has no `bush_depth` takes the same
single full-opacity blit it always did, which is every tile of mtf-meido-action
and all but 28 maps of Nepheshel.

Deliberately left out. **Vehicles** do not sink. RPG_RT exempts only the
airship — ported from a reference implementation's flying check, not
independently confirmed against genuine RPG_RT under wine — so a boat on a
bush tile would in principle wade — but water terrain carries no `bush_depth`
in either test bed, so there is nothing to measure the behaviour against and
a guess would be worse than the omission.
**Battle sprites** never had it: bush depth is a map-layer property and RPG_RT's
battle screen does not consult the terrain for it.

Covered by `scripts/rpg2k_render_check.rb` (the divisor arithmetic, the 1..3
range, scaling to a 16px frame, and the round-up halving), by
`scripts/rpg2k_scene_check.rb` (which terrain depth the hero reads, the jumping
and boarded exemptions, the same/below/above layer gate for events, and the blit
itself — one call on plain ground, a split pair at the water line with the right
source rows and opacities, one half-opacity call when the frame sinks entirely,
and the same through the real `draw_event` path) and by
`scripts/rpg2k_testbed_logic_check.rb`, which sweeps every `Map*.lmu` in each
test bed through the same chipset lookup the scene uses and asserts that every
sinking terrain the games define converts to a real pixel split — and reports
how much shipped ground actually stands on one.
