- **A Turn Right / Turn Left / Turn 180 (or the matching half of Turn 90
  Right/Left/180 Random) inside a Begin Jump / End Jump block now actually
  rotates the diagonal direction it follows, instead of silently leaving it
  unrotated.** This is the narrower sibling of the "Move Forward repeats the
  diagonal in hand" jump-block fix: once a diagonal move sub-command
  (Move Upper-Right/Upper-Left/Lower-Right/Lower-Left) leaves its own
  `[horizontal, vertical]` pair as the jump-scan's tracked direction,
  `Character::TURN_RIGHT`/`TURN_LEFT`/`TURN_180` — which a Turn/Face command
  inside the same jump block looks that direction up in — only had
  cardinal-int keys, so the lookup missed and `#jump_face_direction`'s own
  `|| dir` fallback quietly kept the *unrotated* diagonal in hand. A
  following Move Forward in the same jump block then repeated the pre-turn
  diagonal rather than the turned one. Fixed by keying those three hashes
  with the four diagonal pairs too, rotated the same 90/180 degrees the
  existing cardinal entries already encode. Covered by two new
  `scripts/rpg2k_logic_check.rb` checks (Begin Jump / Move Upper-Right /
  Turn Right / Move Forward / End Jump lands at the Down-Right-rotated
  offset rather than repeating Up-Right; the same route with Turn 180 in
  place of Turn Right cancels out and lands back at the start), both
  confirmed to fail against the pre-fix code before the fix.
