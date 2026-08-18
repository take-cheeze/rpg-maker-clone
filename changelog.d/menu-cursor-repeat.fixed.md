- **Field menu:** holding Down/Up now auto-repeats the cursor in the main
  command list, the Skill/Equip/Status party-status panel, and the End Game
  Yes/No prompt, matching real RPG_RT (the same fix already landed for the
  save/load screen). Reuses this build's existing, wine-verified
  `Input.repeat?` timing — no new behavior invented, just wired in. The
  same gap remains open on the remaining menu screens, tracked in
  `docs/TODO.md`. Covered by new `scripts/rpg2k_scene_check.rb` checks.
