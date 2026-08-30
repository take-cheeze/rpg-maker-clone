- **Field Item menu:** a weapon/shield/armour/helmet/accessory item flagged
  `use_skill` (schema field 71) invoking an Escape- or Teleport-type skill no
  longer warps the party for free -- matching a reference implementation's
  own skill-use handling, not independently confirmed against genuine
  RPG_RT under wine, which for these two skill types only plays the
  invoked skill's sound effect, never a warp of any kind, no matter which
  item kind reached it. Only a genuine type-9 special item still warps
  straight away; a `use_skill` equipment item now prompts for an ordinary
  target the same as any other equipment item, and a successful use plays the
  invoked skill's own success sound instead of Buzzer. Previously, such an
  item warped the party the instant Escape/Teleport access and a registered
  destination both existed, something only a type-9 special item is
  supposed to do.
