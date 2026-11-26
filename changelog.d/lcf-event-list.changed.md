- **RPG2000/2003** event command lists of map event pages, common events and
  troop pages are now read into `LCF::EventList`: the raw command bytes plus a
  compact offset table. An `LCF::EventCommand` is built only when the
  interpreter reads it, so the command lists of a loaded map no longer hold
  one object and one parameter Array per command. A list is read-only; writing
  a field stores a new list.
