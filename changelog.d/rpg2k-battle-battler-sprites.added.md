- The battle screen now **draws the enemy troop as sprites**. RPG2000 is a
  front-view battle, so each visible troop member is drawn from its
  `Monster/<battler_name>` graphic, centred on its database position, over a
  battle background; the party stays represented by the status window (RPG2000
  does not show party battlers). An enemy with no graphic (or a missing file)
  falls back to a solid placeholder block, the same strategy the map uses for a
  missing chipset, and a defeated enemy's sprite is hidden as it falls during the
  per-turn animation. `Game::Enemy` now exposes its `battler_name`. Two pieces
  remain: the per-terrain backdrop (`Backdrop/<name>`, chosen by the tile the
  encounter started on — the encounter request does not carry that terrain yet;
  a plain dark field stands in) and hidden members revealed by a battle event.
  Covered by a new check in `scripts/rpg2k_scene_check.rb` (a sprite per visible
  enemy, centred on its position, below the UI windows and above the backdrop,
  hidden once the enemy is defeated).
