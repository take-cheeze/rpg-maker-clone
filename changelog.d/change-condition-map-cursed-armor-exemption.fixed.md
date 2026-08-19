- **RPG2003 events:** The Change Condition event command can now lift a
  cursed-equipment-forced status condition when run outside battle,
  matching RPG_RT's own map-only exemption — but only for a state left at
  its default "Ends" persistence, never one flagged "Continues after
  battle". Previously a cursed-armor-forced state could only ever be
  cured by unequipping the item, even from a map event specifically
  designed to lift it. Covered by two new `scripts/rpg2k_logic_check.rb`
  checks.
