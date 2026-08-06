- **A chipset that stores no terrain table now reads terrain 1, not terrain 0.**
  RPG_RT omits the whole 162-entry array when every tile of the chipset is
  terrain 1, and that is what 96 of Nepheshel's 100 chipsets and 92 of
  mtf-meido-action's do — so almost every tile in both games was reading an id no
  database row matches. Store Terrain ID stored 0, boat / ship passability fell
  back to on-foot passability instead of the terrain's `boat_pass` / `ship_pass`,
  and the terrain battle backdrop never resolved. A tile id the chip index cannot
  reach now reads the first lower tile's terrain, as RPG_RT does. See ADR 0034.
- **地形ダメージ**: walking onto a tile whose terrain carries a `damage` value now
  takes that much HP off every party member, unless they wear gear flagged
  地形ダメージ無効 (`Game::Actor#prevents_terrain_damage?`, any slot — mtf's is a
  pair of boots, Nepheshel's four include a swimsuit). Like the status slip
  damage it shares a step with, it **cannot kill**: it floors at 1 HP, skips a
  member already down, and flashes the screen red so the loss has somewhere to
  show. Both test beds define damaging terrain (Nepheshel's ダメージ床１/２ at 1
  and 10 HP, mtf's Poison Swamp and Damage Floor at 1 and 2) though neither
  places one on a shipped map. Covered by the logic, scene and test-bed checks.
