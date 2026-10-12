- **Saves are read through typed accessors.** Each field of a `.lsd` is checked
  against its schema type when the save is read, and a save that does not match
  its schema shows as an empty slot with the reason logged, the same way an
  unreadable save does. The on-disk format is unchanged. See docs/adr/0400.
