- **A defending party member's alternate-layout battle sprite now shows its
  Defend pose** (Battler Animation table Pose id 7) instead of staying on
  Idle, matching EasyRPG's `Sprite_Actor::DoIdleAnimation`. The sprite swaps
  the instant Defend commits and reverts to Idle once the round (or, in a
  gauge fight, the individual turn) ends.
