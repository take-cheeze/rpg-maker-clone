- **RPG2000/2003 items:** An item flagged "use skill" (invokes a skill
  directly from the Item menu instead of being equipped) is now listed as
  usable purely by its skill's scope, matching RPG_RT's own quirky
  shortcut for such items. Previously a stat-buff-only skill (no HP/SP/state
  effect) behind such an item was silently hidden from both the field and
  battle Item menus, and an Escape/Teleport-invoking one was wrongly
  withheld from the menu until escape/teleport access and a destination
  existed — RPG_RT actually lists it immediately and only fails the cast
  itself if access/target aren't ready yet. Covered by corrected and new
  `scripts/rpg2k_logic_check.rb` checks.
