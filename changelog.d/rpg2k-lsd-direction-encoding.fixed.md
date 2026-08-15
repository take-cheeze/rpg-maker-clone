- **A hero's, vehicle's or map event's saved facing now decodes correctly
  from a real .lsd save.** It used to read the save format's raw direction
  value as if it were already this engine's own internal convention with no
  conversion at all, silently facing the character the wrong way on
  Continue for anyone facing right, up, or left when they saved (facing
  down happened to read correctly either way, which is why this went
  unnoticed).
