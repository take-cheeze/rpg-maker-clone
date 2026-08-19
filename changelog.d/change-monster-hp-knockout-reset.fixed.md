- **RPG2003 battles:** Killing a troop member via the Change Monster HP
  event command now resets its stat modifiers, attribute-defence rank
  shift and ATB gauge charge immediately, matching RPG_RT — the same
  Knockout reset every other lethal-HP path in battle already applies.
  Previously an enemy buffed (or debuffed) mid-fight, then finished off by
  a scripted Change Monster HP and revived later in the same fight, kept
  fighting with its stale pre-death modifiers and charge intact. Covered
  by a new `scripts/rpg2k_logic_check.rb` check.
