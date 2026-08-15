- **An enemy Transformation no longer heals it back up to the new form's max
  HP/SP.** Confirmed against EasyRPG Player's source: `Game_Enemy::Transform`
  only repoints the monster's database row and refreshes its sprite — it
  never touches current HP/SP. This build force-clamped both down to the new
  form's maximum, silently full-healing a boss whenever its "true form"
  transformation had a lower max HP than its current HP, breaking the
  classic "damage carries across a phase transformation" boss design.
