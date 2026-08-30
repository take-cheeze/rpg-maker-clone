- **Field Item menu:** an ordinary medicine that does not cure Death (an
  Antidote-style item that cures some other state, or a plain HP/MP potion)
  now does nothing at all when used on a downed party member -- no state
  cure, no HP change, no MP change -- matching a reference implementation's
  own item-use handling, not independently confirmed against genuine
  RPG_RT under wine, which aborts the whole call immediately for a
  dead target unless the item cures Death. Previously such an item could
  silently cure an unrelated status condition or restore MP on a KO'd
  member and still be consumed, instead of the Buzzer/kept-item no-op real
  RPG_RT gives.
