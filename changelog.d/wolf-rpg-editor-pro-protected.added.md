- **WOLF RPG Editor (ウディタ/Woditor) Pro-protected data (v3.5) now decrypts**
  instead of only being detected and refused: a protected `Game.dat`/
  `TileSetData.dat`/`CommonEvent.dat`/database's AES-128 key and IV are
  `SHA-512(saltPassword("", dynamicSaltFromTheFile'sOwnBytes,
  hardcodedPerFileTypeStaticSalt))`, derived entirely from bytes the
  protected file's own header already carries plus a small hardcoded
  per-file-type string — no external secret needed, correcting an earlier
  assumption that a 3.5+ release "may be permanently out of reach". A
  from-scratch SHA-512 + AES-128 port (`Wolf::Crypt`), cross-validated
  byte-for-byte against a compiled C++ WolfTL reference and against a full
  Pro-protected round trip of the bundled sample game through the whole
  `Wolf::Project` pipeline and the compiled engine itself. The older v3.1/
  v3.3 sub-schemes and Pro-protected `Map` files are deliberately left
  refused by name — v3.1 has no reference decrypt function to port at all,
  and v3.3's key derivation is a large custom PRNG state machine this
  session could not cross-validate with the same confidence. See
  `docs/adr/0095-wolf-rpg-editor-pro-protected.md`.
