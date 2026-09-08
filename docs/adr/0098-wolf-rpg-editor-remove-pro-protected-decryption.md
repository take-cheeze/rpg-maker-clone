# 98. WOLF RPG Editor: remove Pro-protected data decryption

Date: 2026-09-08

## Status

Accepted

## Context

ADR 0095 shipped `Wolf::Crypt`'s v3.5 Pro-protection AES-128 decryption
(`mruby-wolf/mrblib/wolf_crypt_pro.rb`), and ADR 0093/0096 shipped
`Wolf::DataWolf`, a reader for the encrypted `Data.wolf` packed-release
archive. Investigating why a real, freely-distributable released WOLF RPG
Editor game's `Data.wolf` still could not be opened even after ADR 0096's
compressed-header support (see that ADR's own "Consequences") led to
researching the editor's own version history, and from there to its
official terms of use -- fetched directly from the primary source,
`silversecond.com/WolfRPGEditor/Download.shtml` (a domain this session's
network egress was not initially able to reach; the user unblocked it).
Section 9, verbatim:

> ■9.データ解析・情報共有について■
>
> 9.1. Game.dat、CommonEvent.dat、TileSetData、～Database.dat系、
> MapTree～.dat系、マップファイル(.mpsファイル）に関しては、フォーマットの
> 解析ならびに情報共有を許可するものとします。ただし許可するのは「プロ版の
> プロテクトがかかっていないもの」に限られます(2023/3/1追記)
>
> 9.2. 暗号化データ（「.wolf」ファイル）の解析・解凍、ならびに情報共有は
> 禁止です。(2023/3/1・2024/9/21追記)

("9.1: Format analysis and information-sharing of Game.dat, CommonEvent.dat,
TileSetData, the Database.dat family, the MapTree.dat family, and map files
(.mps) is permitted -- but only for files that do not have Pro-version
protection applied. 9.2: Analysis and decryption of encrypted data ('.wolf'
files), and information-sharing thereof, is prohibited.")

This directly names, and prohibits, exactly what `Wolf::Crypt`'s Pro-
protection decryption did: §9.1's own permission for Game.dat/
CommonEvent.dat/TileSetData/the Database.dat and MapTree.dat families/.mps
maps is explicitly *not* extended to a Pro-protected copy of those same
files -- putting Pro-protected data squarely in §9.2's "encrypted data"
bucket instead, where analysis and decryption are prohibited outright. This
is independent of, and a stronger objection than, the technical DARC_HEAD
puzzle ADR 0096 left open; it applies regardless of whether that puzzle is
ever solved.

`Wolf::DataWolf` (the `Data.wolf` container reader) reads the *unencrypted*
parts of a real archive's header the same way §9.1 permits reading a loose
project's own equivalent files, and the XOR scheme it decodes is closer in
spirit to `RPGXP::RGSSAD`'s own well-established archive obfuscation (not
`Wolf::Crypt`'s Pro-protection AES) -- but it also touches "「.wolf」ファイル"
by name, and the user's own instruction here was specifically to remove the
Pro-protection decrypter and continue with unencrypted game data coverage.
`Wolf::DataWolf` itself was left in place; whether it should be reconsidered
under the same §9.2 reading is a separate, still-open question.

## Decision

- Deleted `mruby-wolf/mrblib/wolf_crypt_pro.rb` in full: the SHA-512/AES-128
  v3.5 decryptor, its v3.1/v3.3 refusal logic, and `.encrypt_v35` (the
  fixture-building inverse).
- Deleted `scripts/wolf_pro_protected_check.rb`, the round-trip fixture
  checker built specifically to validate that decryptor against a real
  project.
- Reverted `wolf.rb`'s `Wolf.open_envelope`/`Wolf::Crypt` and every
  `data.rb` caller (`GameDat`, `TileSetData`, `Database`, `CommonEvents`,
  `Map`) to their pre-ADR-0095 shape: `Crypt.refuse_protected!` raises a
  clear, named error the instant the 0x50 marker is seen, for *any*
  protection version, with no attempt to decrypt. `Crypt.protected?`
  (detection only, not decryption) is unchanged and still covered by its
  own unit test -- detecting the marker to refuse cleanly is not what §9.2
  prohibits.
- Removed the corresponding `mruby-wolf/test/wolf_test.rb` assertions (the
  SHA-512/AES/PRNG unit vectors cross-validated against the compiled WolfTL
  reference, and the `decrypt_v35`/`decrypt_protected`/`encrypt_v35` round
  trips) and `mrbgem.rake`'s load entry.
- Corrected two stale comments the pre-ADR-0095 code had carried (restored
  verbatim by the revert) rather than silently reintroducing them: the old
  "a key that from 3.5 on is not even stored in the game" claim was already
  known wrong by ADR 0095's own research (the key *is* derivable from bytes
  the file itself carries) -- both `wolf.rb`'s module comment and
  `Crypt.protected?`'s own now instead point at this ADR and the terms-of-
  use text above as the actual reason decryption is refused.
- `Wolf::DataWolf`'s own file header (data_wolf.rb) had its Pro-protection
  cross-references updated from "decrypted (v3.5) or refused (v3.1/v3.3)"
  to "refused, with exactly the same message, a Pro-protected loose-tree
  one already is" -- it never itself decrypted anything Pro-protected, only
  documented how the (now-removed) decryption fit around it.

## Consequences

- A Pro-protected file (any protection version) is detected and refused
  with a clear error again, matching this reader's original, pre-ADR-0095
  behavior -- not silently mis-parsed, but also no longer decrypted.
- `docs/TODO.md`'s WOLF section reverts its "Pro-protected data (v3.5)
  decrypted for real" bullet to reflect refusal, with a pointer to this ADR
  for why (not a technical limitation this time, a terms-of-use one).
- `scripts/wolf_testbed_check.rb`/`wolf_interpreter_check.rb`/
  `wolf_data_wolf_check.rb` no longer load `wolf_crypt_pro.rb`; all three
  re-verified green against the real bundled sample game (none of which is
  Pro-protected, so this was expected to be a no-op for them, and was).
- This does not change anything about the *loose-tree, unprotected* data
  layer `mruby-wolf` already reads (`Wolf::Project`, `GameDat`,
  `CommonEvents`, `Database`, `MapTree`, `Map`, the full interpreter) --
  that is exactly what §9.1 permits, and remains this reader's own primary
  focus going forward.
