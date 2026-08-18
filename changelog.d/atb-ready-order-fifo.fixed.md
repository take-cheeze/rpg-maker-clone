- **RPG2003 gauge battle:** When several party members are simultaneously
  ready for their active-time turn, the game now offers the command menu to
  whoever became ready first, matching real RPG_RT — it used to fall back to
  party seat order instead, since every ready gauge is clamped to the same
  maximum and there was no other tie-break. Enemy readiness order is
  unaffected. Covered by a new `scripts/rpg2k3_battle_gauge_check.rb` check.
