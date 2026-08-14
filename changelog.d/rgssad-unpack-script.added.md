- **`scripts/rgssad_unpack.rb`.** Unpacks a packed RPG Maker XP/VX/VX Ace
  archive (`Game.rgssad`/`.rgss2a`/`.rgss3a`) into a loose file tree in
  place, reusing the existing `RPGXP::RGSSAD` reader rather than
  reimplementing the format. Closes the tool half of
  `docs/adr/0047-psp-memory-budget.md`'s P3: the engine's loaders already
  prefer a loose file over the packed archive, so a PSP deployment that
  ships a title unpacked (and excludes the packed archive) avoids reading
  the whole thing into RAM at boot. Verified against real Marshal-encoded
  `.rxdata` packed as both archive versions, unpacked, and diffed
  byte-for-byte against the originals.
