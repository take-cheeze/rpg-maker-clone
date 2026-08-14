- **Continue can now resume with the wrong actor leading the party.**
  Verified under wine against a genuine `RPG_RT.exe` playing a real Nepheshel
  save: chunk 109's party list (`SAVE_INVENTORY` field 1) named actor 1
  ("リト") as the sole member, but RPG_RT's own field menu showed actor 15
  ("デモ用", level 50/600HP) throughout, matching the title chunk's
  `hero_name`/`hero_level`/`hero_hp` exactly. `Game::State.from_lsd` used to
  treat that mismatch as purely cosmetic — chunk 109's party list decided
  *who* the leader was, and a disagreeing title-chunk name was applied by
  just relabelling that actor's `name`, producing a chimera (the right name
  over the wrong level/HP/equipment/skills). It now looks the real leader up
  in the roster by the title chunk's cached name and promotes them instead
  (`Party#promote_to_leader`).
  A second, related bug fed into this: an actor whose `SAVE_PARTY_ACTOR`
  entry carries no real Change Actor Name override encodes that as a single
  `0x01` byte, not an empty string (ADR 0014 flagged this — "reserve actors
  store only a placeholder" — when the field was first decoded, but a later
  change applied it unconditionally anyway). That byte was being applied as
  a genuine override, clobbering every such actor's correct database name
  with a control character and defeating the name-based leader lookup above;
  it is now recognised as "no override" like an empty string already was.
  `scripts/rpg2k_save_load_check.rb`'s leader assertion is updated to check
  against the title chunk (the same oracle the runtime now uses) rather than
  chunk 109's raw party list.
