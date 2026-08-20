- **Battle:** levitating (RPG2003 "airborne") enemies in the same troop now
  bob on their own independently randomized phase instead of all bobbing in
  perfect unison off one shared clock -- matching RPG_RT's own per-battler
  `frame_counter`, randomly seeded for each battler at battle start. A troop
  with several levitating enemies previously had them all rise and fall
  together; now each one drifts in and out of sync with the others, like
  real RPG_RT.
