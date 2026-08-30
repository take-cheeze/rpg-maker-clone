- **A defending party member's alternate-layout battle sprite now shows its
  Defend pose** (Battler Animation table Pose id 7) instead of staying on
  Idle, matching a reference implementation's actor-sprite animation logic,
  ported from that reference and not independently confirmed against
  genuine RPG_RT under wine. The sprite swaps
  the instant Defend commits and reverts to Idle once the round (or, in a
  gauge fight, the individual turn) ends.
