- **Closed-world Ruby**: the battle stat-modifier code, `Party#effective_*`
  and the equip menu's stat rows no longer use a computed `send`, and the map
  scene's `rescue`-modifier field reads (parallax, music, map events) go
  through `LCF.field?`. The lint baseline drops from 32 to 8 offences.
