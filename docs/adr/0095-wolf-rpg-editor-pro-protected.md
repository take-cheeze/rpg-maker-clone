# 95. WOLF RPG Editor: Pro-protected data (v3.5)

Date: 2026-09-07

## Status

Superseded by [ADR 0098](0098-wolf-rpg-editor-remove-pro-protected-decryption.md) --
the decryptor this ADR shipped was removed once the official WOLF RPG
Editor terms of use were found to explicitly prohibit it. This ADR's own
content (the cross-validation methodology, the actual decryption research)
is kept as a historical record, not because any of it still ships.

## Context

`Wolf::Crypt` (ADR 0064's data layer, `mruby-wolf/mrblib/wolf.rb`) has
always been able to *detect* Pro-edition "protected" data -- a byte-1 ==
`0x50` marker every protected `Game.dat`/`TileSetData.dat`/
`CommonEvent.dat`/`*DataBase.dat` (and, in principle, a protected `.mps`
map, see "Consequences") carries -- but never decrypted it, only refused
with a clear error. `docs/TODO.md`'s own "Pro-protected data" bullet
recorded why, and got the reason for the deepest gap wrong:

> actually decrypting it needs the AES/ChaCha scheme `WolfTL`'s
> `WolfDataDecrypt.hpp` implements, and from editor 3.5 on the protection
> key is not even stored in the game (only a hash), so a 3.5+ Pro-protected
> release may be permanently out of reach the way a from-3.5-Pro-protected
> `.wolf` already is for `WolfDec`.

**This is wrong**, and this session ships the fix it claimed was
unreachable. The actual v3.5 scheme (`WolfDataDecrypt.hpp`'s
`v3_5::decryptData`) derives its AES-128 key and IV as

```
SHA-512(saltPassword("", dynamicSaltFromTheFile'sOwnBytes, hardcodedPerFileTypeStaticSalt))
```

-- an **empty** human password, salted only with four bytes the protected
file's own header already carries (`calcDynSalt`, offsets 7/11/12/13/14)
plus a short hardcoded string that differs per file type
(`WolfDataDecrypt.hpp`'s own `PRO_MAGIC` table: `"basicD1"` for `Game.dat`,
`"Commo2"` for `CommonEvent.dat`, `"DBase4"`/`"TilesetA"` for the
databases/tileset). Nothing external to the file is ever consulted. The
"only a hash is stored" intuition the old bullet reached for is not even
true of the *other* two sub-schemes it is trying to describe:
`WolfProtKey.hpp`'s `calcProtKey` recovers the actual human-chosen
protection password itself, in the clear, from an encrypted key block
`Game.dat` carries -- self-decrypting via the same self-contained
`v3_3`-scheme key-derivation chain (header bytes only), then a brute-force
`findKey` over candidate lengths against a self-verifying padding check.
That a *human-readable password* round-trips out of `Game.dat` alone is about
as strong a demonstration as there could be that "the key is not stored in
the game" was never accurate for this protection family, at any version.

The confusion is understandable: `WolfCryptUtils.hpp` defines a function
literally named `isV35` (a `cryptVersion` threshold gate,
`(v >= 0x15E && v < 0x3E8) || v >= 0x3FC`), used inside the *v3.3* scheme's
own key derivation (`WolfAes.hpp`'s `initAES128`, `WolfCrypt.hpp`'s
`initWolfCrypt`) -- a completely different, same-numbered-for-unrelated-
reasons version check from the one that actually selects the "v3.5" *scheme*
this ADR is about (`FileCoder.hpp::load()`'s own dispatch: byte 5, the
`cryptVersion` byte, `< 0x55` selects "v3.1", `< 0x57` selects "v3.3", and
`>= 0x57` selects "v3.5" -- three unrelated schemes, only the last of which
this ADR implements). Reading `WolfDataDecrypt.hpp` far enough to notice
that its `v3_5::decryptData` takes no key/password argument at all (only the
file's own bytes and a `WolfFileType`) is what actually settles it.

## Decision

- **Implemented: v3.5 only** (`mruby-wolf/mrblib/wolf_crypt_pro.rb`, a new
  file reopening `Wolf::Crypt`, loaded right after `wolf.rb` in
  `mrbgem.rake`). This is the scheme a modern editor release -- including
  this repo's own bundled sample game, 3.724 -- would actually use if a
  project were protected, and the only one of the three this session could
  cross-validate with the rigor the earlier ADRs in this series established.
  A from-scratch SHA-512 and AES-128 were ported (see "Cross-validation"):
  - **SHA-512** (`Wolf::Crypt::Sha512`), with WolfTL's two "custom Wolf
    specific" deviations from the textbook algorithm kept
    (`WolfSha512.hpp`'s own comments call both out): non-standard `hPrime`
    initial values, and a final `h[i] += s[i] ^ 0x123456789ABCDEF0` in place
    of plain `h[i] += s[i]`.
  - **AES-128** (`Wolf::Crypt::Aes`): standard S-box/ShiftRows/MixColumns/
    CTR-mode structure, but `WolfAes.hpp`'s own key-schedule expansion
    replaces the textbook `RotWord; SubWord; ^= Rcon` step with WOLF-specific
    byte mangling (its own comment: "This differs between the original and
    the WolfRPG version") -- kept exactly, not "corrected" back to stock AES.
  - **The ProV3P1 keystream** (`decrypt_pro_v3_p1!`): a from-scratch,
    hand-rolled 32-bit mixing function (not AES, not SHA-512) seeded by one
    `xorshift32` step, XORed over the file from offset `0xA` on before AES
    ever runs.
  - **The `aesSize` cap** (`aes_size_for`): a small `msvc_rand`-derived range
    (200..325 bytes) the real AES-CTR region is capped to for anything past
    that size, kept with WolfDataDecrypt.hpp's own shrug of a comment ("that's
    what the code says (probably) and it works") since this reader has no
    better explanation for it either -- confirmed correct behavior (not just
    correct-looking code) by cross-validating a buffer specifically sized to
    trigger it, both against the compiled harness and via a real 380 KB
    `CommonEvent.dat` end to end (see "Cross-validation").
- **Deliberately left unimplemented, refused by name** rather than guessed
  at (`Crypt.decrypt_protected`'s own `elsif` chain on the `cryptVersion`
  byte gives a version-specific error, not a blanket "not supported"):
  - **v3.1** (`cryptVersion < 0x55`). `WolfDataDecrypt.hpp`'s own
    `namespace v3_1 { }` is *empty* -- WolfTL itself never implemented a
    decrypt function for this sub-scheme, only the header-skipping logic
    needed to get past it while decoding a v3.1 `Game.dat`'s embedded
    protection key/project key for other purposes
    (`FileCoder::decryptV3_1`). There is no reference to port; refusing here
    matches this project's own established policy of not shipping guessed-
    at crypto (see `docs/TODO.md`'s `BanInput`(126) entry for the same
    stance in a different corner of this codebase).
  - **v3.3** (`0x55 <= cryptVersion < 0x57`). Genuinely self-contained (see
    `calcProtKey` above) but its key derivation is a large, tightly branch-
    dependent custom PRNG state machine (`WolfRng.hpp`'s `customRng1`/
    `customRng2`/`customRng3`, `rngChain`'s dozen modulus-keyed branches,
    `aLotOfRngStuff`'s nested nine-way switch) built to key an AES stream for
    exactly one file (`Game.dat`) via `initCrypt`'s header-byte-derived
    seeds. This is real, meaningful additional scope: porting and cross-
    validating it with the same rigor v3.5 got (real compiled-reference
    vectors for every branch, not just the happy path) was not something
    this session could do with confidence in the time available. A single
    off-by-one in that branch tree produces a *plausible-looking but wrong*
    key, not a crash -- exactly the "silently wrong is worse than refusing"
    case this whole task was framed around, so it is refused rather than
    shipped half-verified.
  - **Pro-protected `Map` files.** `WolfDataDecrypt.hpp`'s own `PRO_MAGIC`
    table (the per-file-type static salt / plain-file-prefix map v3.5
    decryption needs) has no entry for `WolfFileType::Map` --
    `PRO_MAGIC.at(WolfFileType::Map)` would throw `std::out_of_range` in the
    reference implementation itself. Even WolfTL cannot decrypt a
    Pro-protected map, so `Crypt::FileType::MAP` is deliberately absent from
    this reader's own `PRO_MAGIC` too, and `Map#initialize` (`data.rb`)
    refuses by name rather than attempting it.
- **One seam, not scattered conditionals**
  (`Wolf::Crypt.decrypt_protected(data, what, file_type)`), mirroring how
  `Wolf::Project#initialize` picked a backing store through one seam for the
  Data.wolf PR (ADR 0093): returns `data` unchanged when it is not
  Pro-protected at all; the decrypted replacement (shaped exactly like a
  plain, never-protected UTF-8 file -- indicator byte, magic, UTF8 marker --
  so nothing downstream needs to know decryption happened) for a v3.5 file
  of a known type; and raises a version- and file-type-specific `Wolf::Error`
  for everything this ADR leaves unimplemented. `Wolf.open_envelope` (used
  by `GameDat`/`TileSetData`/`CommonEvents`/`Database`) and `Map#initialize`
  both now call it, each passing its own `Crypt::FileType`.
- **Portability**: byte-wise arithmetic only, matching `rgssad.rb`'s and
  `data_wolf.rb`'s own discipline -- SHA-512's 64-bit words are 8-element
  Arrays of bytes (never a native/bignum 64-bit integer), and the whole
  protected file is handled as one byte String throughout (`getbyte`/
  `setbyte`/`byteslice`), never turned into one big `Array` of per-byte
  integers -- a real `CommonEvent.dat` routinely exceeds mruby's
  `MRB_ARY_LENGTH_MAX` (131072), and an earlier version of this port that
  did exactly that raised `ArgumentError: array size too big` the first time
  it ran against a real file (caught by the boot-check below, not by any
  CRuby-level check -- see "Cross-validation"). See
  `wolf_crypt_pro.rb`'s own file header for the full portability write-up,
  including a second, harder-won rule (`Numeric#zero?`/`#negative?`/
  `#positive?` do not reliably resolve for `Integer` in this build's
  `mrbtest` binary, for reasons not fully diagnosed -- `== 0`/`< 0`/`> 0`
  are used instead).

## Cross-validation

This is the part of this task the calling instructions called "close to
mandatory": every primitive was checked against **real compiled C++ output**
from WolfTL's own vendored, unmodified headers
(`/home/user/3rdref/WolfTL/WolfTL/WolfCrypt/*.hpp`), not hand-traced from
reading them.

- A standalone harness (`main.cpp`, `#include`s `WolfCrypt/WolfCrypt.hpp`,
  `WolfCrypt/WolfDataDecrypt.hpp` and `WolfCrypt/WolfProtKey.hpp` directly,
  no `WolfRPG/FileCoder.hpp` and so none of its `_WIN32`-only SJIS/UTF-8
  helpers) compiled cleanly with `g++ -std=c++23` after two trivial missing-
  `#include` fixes in the vendored headers themselves (`<cstring>` for
  `memcpy`/`strlen` -- not a portability rewrite, `WolfCrypt.hpp` genuinely
  never included it). It exercises, and prints hex output for: `SHA-512`
  digests of three inputs (a v3.5-shaped salted password, `"abc"`, and the
  empty string), `calcDynSalt` on a synthetic buffer, AES-128 key expansion
  and a CTR round trip, three chained `xorshift32` steps, five chained
  `msvc_rand` values, the `decryptProV3P1` keystream alone, and the full
  `v3_5::decryptData` pipeline for all four known `WolfFileType`s plus a
  2000-byte buffer specifically sized to exercise the `aesSize` cap branch.
  This harness's own source is not checked into the repo (it lives in this
  session's scratchpad); the exact commands to reproduce it are: compile
  the `main.cpp` shown in this session's transcript (or reconstruct it from
  this ADR's own description of what it exercises) with
  `g++ -std=c++23 -I /home/user/3rdref/WolfTL/WolfTL -O2 -o harness main.cpp`
  and run it -- reproducing it is mechanical, the point is that the numbers
  below came from a real compiler and a real, unmodified reference
  implementation, not from this session's own reasoning about what the C++
  "should" do.
- `mruby-wolf/mrblib/wolf_crypt_pro.rb` was prototyped and checked against
  that harness's recorded output under CRuby first (byte-for-byte, for
  every primitive and the full pipeline, small and large buffers, all four
  file types), then ported into the real mrbgem. `mruby-wolf/test/wolf_test.rb`'s
  Pro-protected v3.5 section embeds the same recorded hex vectors as real
  unit-test assertions -- not "trust the prototype", a permanent regression
  guard.
- **A real end-to-end round trip against a genuine 660-file project**:
  `scripts/wolf_pro_protected_check.rb` (new, mirroring
  `scripts/wolf_data_wolf_check.rb`'s own "no real fixture exists, so build
  a synthetic one from this reader's own inverse function" approach) copies
  the downloaded sample game's `Data/BasicData` tree, Pro-protects
  `Game.dat`/`TileSetData.dat`/`CommonEvent.dat`/all three `*DataBase.dat`
  files with `Wolf::Crypt.encrypt_v35` (the genuine inverse of `decrypt_v35`
  -- AES-CTR and the ProV3P1 XOR keystream are both self-inverse given the
  same key, so this is not a toy stub), and asserts every field
  `wolf_data_wolf_check.rb`'s own checker checks comes back identical to the
  unprotected original through the *whole* `Wolf::Project` pipeline. This
  caught the `MRB_ARY_LENGTH_MAX` bug above (CommonEvent.dat's real 380 KB
  content is what actually exceeded the cap; nothing smaller would have) and
  a copy/paste transcription error in one hand-typed hex expected value in
  the unit tests (both fixed; see "Consequences").
- **The compiled `rpg_maker_clone` binary itself**, booted headlessly
  (`--test_play`, under `xvfb-run`) against both the unmodified downloaded
  sample game and a full Pro-protected copy of it (all six files above
  protected via the same `encrypt_v35` fixture builder) -- both reach the
  map (`[Wolf-MAP] map=0 x=6 y=6` in the log), confirming the whole pipeline
  (mrb bytecode included, not just the CRuby-level checks) works end to end
  in the real engine, not only under the CRuby test harness.

## Consequences

- `docs/TODO.md`'s "Pro-protected data" bullet flips to done for v3.5, with
  v3.1/v3.3/Map named as the specific, deliberate remaining gaps (today's
  date).
- Two real bugs were caught only by the stronger checks in this list, not by
  the CRuby-level prototype or unit tests alone -- worth naming plainly,
  since "ship crypto only when confidently cross-validated" is this whole
  task's own framing:
  1. **`Numeric#zero?`/`#negative?`/`#positive?` do not resolve for
     `Integer`** in this build's actual `mrbtest` binary, despite
     `mruby-numeric-ext` being compiled in and `Integer.ancestors` naming
     `Numeric` -- only found by running `ctest -R mruby_test` for real (the
     CRuby prototype, and even a hand-rolled CRuby test harness, cannot see
     this: CRuby's own `Integer#zero?` works fine). Fixed by using `== 0`/
     `< 0`/`> 0` throughout instead, matching the rest of this codebase's
     existing (if implicit) avoidance of `mruby-numeric-ext` methods.
  2. **Turning a whole protected file into one `Array` of per-byte integers
     raises `ArgumentError: array size too big`** against a real
     `CommonEvent.dat` (380,888 bytes, past mruby's 131,072-element
     `MRB_ARY_LENGTH_MAX`) -- found only by booting the compiled engine
     against `scripts/wolf_pro_protected_check.rb`'s real-project fixture,
     not by any unit test with a small synthetic buffer. Fixed by reworking
     `decrypt_pro_v3_p1!`/`region_xcrypt`/`encrypt_v35` to walk/splice a
     byte String via `getbyte`/`setbyte`/`byteslice` instead, the same
     discipline `rgssad.rb`'s `DECRYPT_CHUNK` and `data_wolf.rb`'s `CHUNK`
     already established for exactly this reason; `mruby-wolf/test/wolf_test.rb`
     gained a dedicated regression test (a 200,000-byte body, built in
     bounded chunks so the *test itself* does not re-trip the same cap).
- 14 new CRuby/mruby-level unit tests (`mruby-wolf/test/wolf_test.rb`): SHA-512
  against three reference digests, `calcDynSalt`, AES-128 key expansion +
  CTR (plus its own round trip), `xorshift32`, `msvc_rand`, `decrypt_v35`
  against the compiled harness for all four known file types, the `aesSize`-
  cap-triggering large buffer, the `FileType::MAP` refusal, `decrypt_protected`'s
  pass-through/decrypt/version-refusal behavior (2 tests), `encrypt_v35`/
  `decrypt_v35` round trips (small, large-enough-to-cap, and past the
  Array-length cap).
- **Trade-offs / follow-up**, all refused rather than guessed, exactly where
  "Decision" says: v3.1 (no reference implementation exists to port at all),
  v3.3 (a real reference exists, but its key derivation is large and
  intricate enough that this session could not cross-validate it with
  confidence in the time available -- a genuine follow-up candidate, not a
  dead end), and Pro-protected `Map` files (out of scope for the same reason
  it is out of scope in WolfTL itself). None of these block the common
  case: a modern (3.5+) Pro-protected release -- the only kind a project
  built with a current editor, such as this repo's own bundled 3.724 sample,
  would ever produce -- is fully decrypted.
