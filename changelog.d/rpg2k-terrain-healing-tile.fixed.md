- **A terrain tile with a negative `damage` value now heals the party each
  step instead of doing nothing, bypassing 地形ダメージ無効 (terrain-damage
  immunity) gear entirely while doing it.** Ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: a terrain row carries one plain signed damage field, and
  a negative value applies to every party member unconditionally, healing
  rather than hurting — the immunity gear only blocks positive damage. A
  healing tile also never flashes the screen, unlike a damaging one.
