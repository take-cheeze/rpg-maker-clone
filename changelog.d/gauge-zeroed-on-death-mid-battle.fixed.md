- **RPG2003 Gauge battle system:** A battler's active-time gauge now
  zeroes the instant a lethal hit lands, matching RPG_RT, instead of only
  once the fight itself ends. Previously an ally charged up and then
  killed mid-fight kept its old charge intact until battle end, so
  reviving them with an ordinary Full Heal or revival item let them act
  again almost immediately instead of charging back up from empty like
  everyone else. Covered by a new `scripts/rpg2k_logic_check.rb` check.
