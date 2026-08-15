- **Elemental-resistance equipment (armor/shield/helmet/accessory) now
  actually resists that element**, instead of having no effect on the
  wearer. Confirmed against EasyRPG Player's source
  (`Game_Actor::GetBaseAttributeRate`): a defensive item flagging an
  attribute in its own `attribute_set` grants a flat +1 defensive rank for
  that element, on top of the actor's own database rank. This build parsed
  the field but only ever consumed it on the offensive (weapon) side, so a
  "Fire Ring" or similar resistance item had no defensive effect at all.
