- **Battles:** Inflicting the Knockout state mid-battle — via a skill or
  weapon's own state effects, or the Change Monster Condition event command —
  now actually fells the target, matching real RPG_RT — it used to only mark
  the state without touching HP, so an "instant death" skill/weapon or a
  troop page silently did nothing observable, and the target kept fighting.
  Curing Knockout on a downed target now correctly revives it to 1 HP too.
  Covered by new `scripts/rpg2k_logic_check.rb` checks.
