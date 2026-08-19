- **RPG2003 battles:** An enemy's own Auto Destruction (self-destruct)
  basic action now plays its explosion sound effect, matching RPG_RT.
  Previously a self-destructing monster played no sound at all — the
  same fixed cue that always accompanies the "X explodes!" banner in
  RPG_RT, regardless of whether the blast actually defeats a target, was
  entirely missing. Covered by new `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb` checks.
