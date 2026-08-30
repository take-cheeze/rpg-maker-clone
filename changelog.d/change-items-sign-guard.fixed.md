- **Change Items event command:** a variable-sourced amount whose sign
  contradicts the chosen operation (a negative value under "Add", or a
  value that flips positive under "Remove") is now a no-op, instead of
  silently flipping direction -- matching RPG_RT's own Change Items
  command handling, ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine, which refuses
  to apply the command at all when the computed sign doesn't match "Add
  item can't be
  used to remove an item and remove item can't be used to add one".
  Previously, an event driving the amount through a variable that could
  go negative (arithmetic on other variables, a computed stock delta)
  would gain items on a "Remove" or lose them on an "Add". Change Gold is
  unaffected -- real RPG_RT applies no such guard there.
