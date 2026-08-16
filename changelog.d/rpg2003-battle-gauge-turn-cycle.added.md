- The **RPG2003 gauge battle now runs on its active-time turn cycle** (ADR
  0054): a gauge presentation (battle_type 2) fight replaces the 2000
  sequential round order with "whose gauge is full" — every combatant's charge
  gauge fills each frame, the first one full opens the command menu for a
  controllable party member (the fight pauses on it, Wait-mode behaviour) or
  fires the action of anyone else (enemy AI included) automatically, and acting
  resets the gauge so it refills. `Game::Battle#begin_gauge_turn` queues one
  battler per action (bumping its own per-battler turn counter for the
  RPG2003 page conditions, never the round count), and `RPG2k3::Scene::Battle`
  runs the whole cycle through an `:atb` idle loop — with every override gated
  on battle_type 2, so the traditional and alternative 2003 presentations and
  every RPG2000 fight keep the unchanged round machine. A gauge fight no longer
  shows the Fight/Auto/Escape options window; its once-per-fight menu opens for
  the first ready actor instead. Covered by new `rpg2k3_battle_gauge_check.rb`
  and `rpg2k_scene_check.rb` checks driving a real gauge battle through the
  2003 scene; the native boot check's 2003 battle pass stays green.
