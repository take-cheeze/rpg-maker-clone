- **RPG2003 status effects:** Full Recovery now re-inflicts any state the
  actor's currently-equipped cursed armor forces, matching RPG_RT --
  previously a state a map-side Change Condition had legitimately lifted
  (RPG_RT's own map-only exemption) stayed gone through a subsequent Full
  Recovery instead of being restored. Covered by extending an existing
  `scripts/rpg2k_logic_check.rb` check.
