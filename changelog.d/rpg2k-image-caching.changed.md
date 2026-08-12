- **`Scene::Map` now caches all named RPG2000/2003 graphics through one shared
  lookup** instead of three separate ad hoc hashes (event CharSets, picture
  sources, the party leader's CharSet). The consolidation also extends
  caching to three loaders that previously re-decoded from disk on every
  call: the battle backdrop, battler graphics, and — the highest-impact
  case — the battle animation sheet, which used to be reloaded and
  re-decoded on every single animation play, on the map and in battle alike.
  Sprites that used to own and dispose their battler/backdrop bitmap now
  release only the sprite; the bitmap is a shared cache entry that outlives
  any one sprite for the rest of the map visit.
