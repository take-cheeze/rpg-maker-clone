- Save/Continue (this engine's own Marshal save format, `Party#to_h` /
  `#load_state`) no longer fabricates a Change Class for an actor that merely
  *starts* in an RPG2003 class. It called `Actor#restore_class` whenever an
  actor's saved meta carried any `class_id`, which every actor with a
  database-assigned starting class does whether or not a live Change Class
  event ever ran — and `#restore_class` unconditionally sets
  `@class_changed`, which is what `#curve_row` gates the class row on instead
  of the actor's own row. Every such actor silently switched onto their
  class's growth curve, skill-learn table and EXP curve on the very next
  Continue, mis-deriving their level (`#load_state` restores EXP and
  re-derives level from it) and losing skills learned past level 1. Found via
  a real RPG2003 game (see the `killer-knights-testbed` fragment) whose
  companions level through Change Level rather than Change EXP, which is what
  made the wrong curve's mis-derived level actually visible. `#to_h` now also
  carries `Actor#class_changed?`, and `#load_state` only calls
  `#restore_class` when it says a change genuinely happened — matching how
  `#to_lsd`/`.lsd` chunk 108 already distinguish the two via its own `-1`
  "never changed" sentinel. Covered by a new fixture check in
  `rpg2k_logic_check.rb`.
