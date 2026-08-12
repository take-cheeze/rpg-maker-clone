- RPG Maker 2000: the event page's "doesn't overlap another event" flag
  (`overlap_forbidden`, LCF page field 35) now gates collision. It is a
  fourth, independent collision axis on top of priority type: a blocker with
  the flag set collides with a mover regardless of the mover's own layer (a
  below-characters "pen gate" still blocks a same-layer NPC wandering through
  it), and a mover with the flag set likewise collides with a blocker of any
  layer. Wired into every call site that already gated on layer — hero
  movement, event movement/jump landing, and boat/ship/airship movement.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks.
