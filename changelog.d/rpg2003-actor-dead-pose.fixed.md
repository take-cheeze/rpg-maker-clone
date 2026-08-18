- **A knocked-out party member's alternate-layout battle sprite now shows its
  Dead pose** (Battler Animation table Pose id 4) instead of drawing no
  sprite at all, matching EasyRPG's `Sprite_Actor::DoIdleAnimation`, whose
  monster branch resolves the Knockout state to `AnimationState_Dead` rather
  than hiding it. The sprite swaps the instant a round (or, in a gauge fight,
  an individual turn) ends with the member felled, and a member already KO'd
  when the fight opens gets the pose immediately.
