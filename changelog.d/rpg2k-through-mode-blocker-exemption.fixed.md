- **A blocker's own Through Mode now exempts it from collision** in
  `Scene::Map#passable?`, `#char_passable?`, and `#step_movement`'s
  touch-trigger dispatch — matching EasyRPG's own `WouldCollide`
  (`src/game_map.cpp`): `if (self.GetThrough() || other.GetThrough()) return
  false;`, *either* side's flag, not only the mover's own (already handled).
  Previously only a character's own Through Mode let *it* cross obstacles;
  another character (the party included) walking up to *it* still collided
  with a same-layer event even after that event switched its own Through
  Mode on via a Move Route sub-command. This is exactly how an RPG2000
  "hidden door" idiom opens itself — a same-layer Player Touch event that,
  once triggered, sends itself through a Move Event: Through Mode on, step
  aside, done — and Nepheshel's own copy-pasted "HiddenDoor" event (well over
  a hundred maps) used exactly this shape. The reveal fired correctly, but
  the party stayed walled off by a stale layer check `#passable?`'s own,
  now-matching exemption would already have let pass. Covered by two new
  checks in `scripts/rpg2k_scene_check.rb`, one per direction (the party
  crossing a Through Mode event, and an ordinary map event's own custom-route
  movement crossing one).
