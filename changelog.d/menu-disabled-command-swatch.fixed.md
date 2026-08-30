- **Field menu:** A command the menu will refuse (Save with saving turned
  off, Item/Skill/Equip with an empty party) now grays out, reading the
  windowskin's own disabled-text swatch -- matching RPG_RT's own
  command-row drawing, ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine. Previously
  every row drew in the same plain
  white regardless of whether it was actually usable, even though selecting
  a disabled command already correctly refused with just a buzzer.
