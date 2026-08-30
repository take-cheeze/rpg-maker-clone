- **A jumping event now arcs instead of teleporting.** Begin Jump / End Jump
  moved the character in one step and the sprite went with it, so the hop that
  clears a chasm was drawn as a blink. The sprite slides across the whole hop and
  is lifted along the way, a port of a reference implementation's jump-height
  curve (peaking at 21px on a 16px tile), not independently confirmed against
  genuine RPG_RT under wine. The lift is applied where the sprite is
  blitted, not to its position, so the camera and the draw order still see it on
  the ground.
- **A jump that lands on the tile it left was impossible.** `char_can_land?`
  refused it because the tile is occupied — by the jumper itself. RPG2000 hops in
  place, and a character never blocks its own landing.
