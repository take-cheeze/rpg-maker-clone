- **RPG2003 battles:** A Switch-type skill cast from the battle Skill menu now
  actually flips its configured switch, matching RPG_RT -- previously it only
  ever spent its SP and did nothing else, unlike the identical field-menu
  cast (which already worked) and a battle switch *item* (fixed earlier).
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
