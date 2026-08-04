- **Smooth event movement** — map events now slide between tiles instead of
  hopping. `Scene::Map` gives each event the same pixel-interpolation model as
  the player: a single-tile cardinal step eases from the old tile to the new one
  over `TILE/SPEED` frames (`event_pixel`, driven by a per-event
  `disp`/`move_count` slide started in `reoccupy`), and the walk animation only
  cycles while the sprite is actually sliding — a resting event shows its page
  pose. A longer hop (jump or multi-tile move) snaps rather than streaking
  across the map. Covered by new checks in `scripts/rpg2k_scene_check.rb`.
