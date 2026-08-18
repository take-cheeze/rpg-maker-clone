- **RPG2000/2003 field menus:** A self- or all-ally-scope field skill/item
  (a self-buff, an all-ally healing potion, ...) now opens the same
  target-confirm screen every other field skill/item does before casting,
  matching real RPG_RT — previously it applied on the very first Decision
  press with no way to back out. The cursor is locked to who the effect
  already lands on (the caster, or the whole party) rather than free to
  move, but Decision still casts and Cancel still backs out with nothing
  spent or consumed. Covered by seven new `scripts/rpg2k_scene_check.rb`
  checks.
