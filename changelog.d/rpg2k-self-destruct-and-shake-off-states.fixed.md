- **A self-destruct now applies the same strong-defence double-halving a
  basic attack does**, instead of stopping at ordinary Defend's single
  halving. A self-destruct against a defending, strong-defence party member
  previously dealt roughly double the correct damage.
- **A self-destruct and an offensive skill can now shake a survivor's status
  loose, the same way a basic attack already could.** Confirmed against
  EasyRPG Player's source: the status-release mechanic is shared across all
  three attack types, scaled by each one's own physical rate (skills scale by
  their own `physical_rate` field; basic attacks and self-destructs always
  apply it in full). A blinded or poisoned target that survived a monster's
  self-destruct, or a physical-leaning attack skill, previously stayed
  afflicted no matter how hard the blow landed.
