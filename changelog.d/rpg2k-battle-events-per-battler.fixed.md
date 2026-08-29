- RPG Maker 2000: **battle-event pages are checked between every acting
  battler now, not just once per round.** A reference implementation's
  battle-event scheduling runs before the
  round-start menu *and* — per its own source comment — "before each battler acts
  and also right after the last battler acts," not independently confirmed
  against genuine RPG_RT under wine, so a page whose condition
  turns true mid-round (an enemy's HP crossing a threshold from an earlier
  attacker's hit, say) fires immediately, before the next battler in the same
  round acts, rather than waiting for the next round's check.
  `Scene::Map#drive_battle_animate` now checks for a matching page between
  every battler's action (a `battler_boundary` flag set once
  `Game::Battle#step_action` finishes draining one battler's whole action —
  a dual-wield swing or an all-target Skill/Item queues several hits from the
  *same* battler, and the check belongs between battlers, not between hits),
  threading a `return_phase` through `#run_battle_events` /
  `#leave_battle_event_phase` so a page started mid-round resumes the
  animation loop afterward instead of jumping to the command menu partway
  through a round. Every page still fires exactly once per turn regardless of
  how many times it's checked. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the pre-fix
  code.
