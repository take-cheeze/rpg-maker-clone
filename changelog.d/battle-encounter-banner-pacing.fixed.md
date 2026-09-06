- The **battle encounter banner** now paces itself the way genuine RPG_RT
  does, measured frame by frame under wine: its lines appear one at a time
  (8 frames apart) and accumulate in the one panel instead of all showing at
  once, the 70-frame hold runs from the *last* line rather than the first,
  and pressing Decision ends that hold early once 30 frames of it have
  passed (it used to ignore input entirely). Covered by new
  `scripts/rpg2k_scene_check.rb` checks, which also pin the victory panel's
  rect, keypress arrow and Cancel-closes behaviour as confirmed correct.
