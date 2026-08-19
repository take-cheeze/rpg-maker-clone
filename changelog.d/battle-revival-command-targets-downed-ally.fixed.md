- **RPG2003 battles:** A revival item or Death-curing skill queued against
  an already-downed ally now actually resolves and revives them, matching
  RPG_RT. Previously every in-battle Skill/Item command fizzled outright
  on a downed target with no SP or item spent — even a revival one — so a
  downed ally could be selected as an item/skill's target (already
  correctly allowed) but the action silently did nothing, leaving them
  dead. The field-menu equivalents were unaffected; only the in-battle
  path had this gap. Covered by new `scripts/rpg2k_logic_check.rb` checks.
