- **Skills and items play their battle animation.** Every skill and every item in
  both test beds names one — 306/306 and 1200/1200 in Nepheshel, 134/134 and
  100/100 in mtf-meido-action, all resolving to real rows in tables of 500 and
  150 animations — and none of them played: a fight was a status panel, a line of
  text and an HP number going down. The frame-by-frame player the map's Show
  Battle Animation command already used is now shared: `build_animation` takes an
  explicit id and target pixel, a battle animation is placed in screen pixels
  rather than map ones and resumes no interpreter when it ends, and the round is
  paced by the animation in place of the fixed banner timer. It plays centred on
  the targeted enemy's sprite (found by the target's index, so two monsters
  sharing a name cannot be confused), or over the middle of the screen for an
  action aimed at a party member, since RPG2000's first-person battle draws no
  ally sprite. A plain attack's animation comes from the equipped weapon, which
  the log entry does not carry, and is left for its own change. See ADR 0037.
