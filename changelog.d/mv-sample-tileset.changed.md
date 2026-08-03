- MV sample now renders a visible tiled map. The committed sample project
  (`data/mv-sample`) previously had a blank tileset and an all-zero map, so it
  booted to a black screen. `scripts/gen-mv-sample.py` now authors a tiny
  two-tile A5 tileset (a grass floor and a stone wall, written as a hand-encoded
  PNG — no Pillow dependency) and fills the map's ground layer with a
  wall-bordered floor room. This exercises the engine's canvas `Tilemap`
  rendering path (previously untested for want of tileset art) and makes the MV
  sample/movement smoke screenshots show an actual room instead of black. Walls
  block movement; the interior stays freely walkable.
