- **The XP API-gap list is now checked against a second game.** It derives its
  "needed" column from one test bed's 90 script sections, which is its obvious
  weakness. Diffing the RGSS surface against `data/PrayforYou` — a released game
  with 103 sections including a custom ATB battle system, its scripts inside an
  encrypted `Game.rgssad` — turns up three calls the bed never makes
  (`Font.default_name`, `RPG::Cache.animation`, `Table.new`) and none that only
  the bed makes. All three are already provided.
