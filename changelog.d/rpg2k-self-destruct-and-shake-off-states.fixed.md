- ~~A self-destruct now applies the same strong-defence double-halving a
  basic attack does, instead of stopping at ordinary Defend's single
  halving.~~ **Reverted:** a genuine wine capture showed a defending,
  strong-defence target's own self-destruct damage lands the same as an
  ordinary defending target with the flag off, not halved a second time —
  genuine RPG_RT does not appear to read `strong_defence` in this formula at
  all. `Game::Battle#enemy_autodestruct` only ever applies Defend's ordinary
  single halving again now, regardless of the flag.
- **A self-destruct and an offensive skill can now shake a survivor's status
  loose, the same way a basic attack already could.** Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine: the status-release mechanic is shared across all
  three attack types, scaled by each one's own physical rate (skills scale by
  their own `physical_rate` field; basic attacks and self-destructs always
  apply it in full). A blinded or poisoned target that survived a monster's
  self-destruct, or a physical-leaning attack skill, previously stayed
  afflicted no matter how hard the blow landed.
