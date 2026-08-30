- **The battle command/target/skill/item screens now play RPG2000's system
  SE too.** Extends the field-menu/title-screen system-SE work to a much
  larger surface: cursor movement on the command, enemy-target, skill,
  item and ally-target lists all play Cursor SE; confirming a command
  plays Decision (or Buzzer when Skill/Item would open with nothing usable,
  or a chosen skill is unaffordable); every cancel plays Cancel; and a
  successful Escape plays a dedicated Escape SE right before the battle
  ends, while a failed attempt plays nothing at all -- all ported from a
  reference implementation's battle-scene source, not independently
  confirmed against genuine RPG_RT under wine.
