- **RPG2000/2003:** a map's tile layers no longer keep their chunk bytes next
  to the decoded `LCF::ShortArray`, and short strings decoded from LCF
  (charset, face and sound names, event command strings) are frozen and
  shared between records through a 64-entry table. Reading a layer twice
  gives the same `LCF::ShortArray`, and changing it in place shows in the
  map's `#to_lcf`.
