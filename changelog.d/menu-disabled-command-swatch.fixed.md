- **Field menu:** A command the menu will refuse (Save with saving turned
  off, Item/Skill/Equip with an empty party) now grays out, reading the
  windowskin's own disabled-text swatch -- matching RPG_RT's own
  `Window_Command::DrawItem`. Previously every row drew in the same plain
  white regardless of whether it was actually usable, even though selecting
  a disabled command already correctly refused with just a buzzer.
