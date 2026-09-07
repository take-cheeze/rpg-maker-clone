# 93. WOLF RPG Editor: packed releases (`Data.wolf`)

Date: 2026-09-07

## Status

Accepted

## Context

`mruby-wolf` (ADR 0064) only ever read a loose `Data/` project tree on disk
-- the shape a game runs in from inside the editor. A **released** WOLF RPG
Editor game instead ships its whole tree packed into a single encrypted
`Data.wolf`, the same way a released RPG Maker XP/VX/VX Ace game packs its
`Data/`/`Graphics/`/... tree into one `Game.rgssad`/`.rgss2a`/`.rgss3a`
(`RPGXP::RGSSAD`, ADR 0010). Without a reader for it, only a project still
sitting in the editor's own working tree was playable -- not a single
released, downloadable WOLF RPG Editor game, which is the common case a
player actually has.

`Data.wolf` is not a WOLF-specific format: it is a stock DxLib "DXA" archive
(the archiver dxlib.o.oo7.jp ships, used by countless Windows games built on
DxLib, not just WOLF RPG Editor ones), XOR-encrypted with a key that differs
per editor version. [WolfDec](https://github.com/Sinflower/WolfDec) and
[UberWolf](https://github.com/Sinflower/UberWolf) already document this --
`docs/TODO.md`'s own "Packed releases" entry named both as the sources to
work from; only WolfDec is vendored locally (`/home/user/3rdref/WolfDec`, no
UberWolf checkout available this session), and it turns out to be sufficient
on its own: WolfDec bundles DxLib's actual archiver source
(`3rdParty/DXArchive.cpp`/`.h`) to implement its own decryption, which is a
complete, primary specification of the format -- not a black box to reverse-
engineer from WolfDec's own behaviour.

No `Data.wolf` fixture exists anywhere in this repo or its `data/`
directories to test against (the bundled sample game, downloaded by
`scripts/download-wolfrpg-sample.bash`, is a loose tree -- released games are
not freely redistributable the way SmokingWOLF's own sample project is, so
there is no first-party packed fixture available the way ADR 0027's *Pray for
You* is for RPG Maker XP). This reader is therefore validated the way
`RPGXP::RGSSAD`'s own writer half is (`.pack_v1`/`.pack_v3`, its own fixture
builders, exist for exactly this "no real archive to test against" reason):
a synthetic-fixture round trip, cross-checked line-by-line against
`DXArchive.cpp` while writing it (see `mruby-wolf/mrblib/data_wolf.rb`'s own
file header for the format walk-through, and "Consequences" below for the
stronger check this ended up affording).

## Decision

- **`Wolf::DataWolf`** (`mruby-wolf/mrblib/data_wolf.rb`), the same shape as
  `RPGXP::RGSSAD`: opened for streaming, seekable reads rather than loaded
  whole (the same PSP-memory-budget reasoning, docs/adr/0047 Finding 2 -- a
  released game's `Data.wolf` packs every map, chipset and character sheet
  into one file well past the PSP's ~24 MB RAM budget by itself), byte-wise
  arithmetic only (no bignum bitwise operators, matching `RGSSAD`'s own
  discipline -- CRC32 alone routinely produces 32-bit values past mruby's
  32-bit `mrb_int`, per `build_config.rb`'s own mruby-bigint note), decrypted
  bytes assembled in `Array#pack("C*")`-bounded chunks to stay under mruby's
  array-length cap, and a `.pack(files)` class method as the inverse writer
  and fixture builder, mirroring `RGSSAD.pack_v1`/`.pack_v3`.
- Auto-detects which of DxLib's/WolfDec's per-editor-version keys the
  archive needs (`KNOWN_KEYS`, the current-format entries from WolfDec's own
  `main.cpp` key table) by trying each in turn and keeping the first whose
  decrypted root directory record passes a bounds/sanity check -- the same
  thing WolfDec's own `main.cpp` does (`detectMode`), because there is no
  better way: nothing in the archive states which editor version built it.
- Deliberately out of scope, refused with a clear, named error rather than
  mis-parsed -- the file header's "Scope" section has the full reasoning:
  - **Compressed entries.** DXA can Huffman+LZ-compress its header table and
    individual files (~1000 more lines of `Huffman.cpp`/`DXArchive.cpp` to
    port). WOLF's own asset bodies are already independently LZ4-compressed
    at the *content* layer before ever reaching the archive (`Wolf::LZ4`),
    which argues against `Data.wolf` also paying for DXA's own redundant
    compression, but that is an expectation, not a fact this session could
    confirm against a real file -- so a compressed header or entry is
    detected and refused, never silently mis-decoded.
  - **The older DXA v5/v6 container** the 2.0x editor releases used
    (`DXArchiveVer5`/`Ver6` in WolfDec) -- structurally different from the
    v8 format above; `KNOWN_KEYS` only covers 2.281 and later.
  - **Pro-protected data** is not handled specially at all, because it does
    not need to be: Pro protection (byte 1 == `0x50`, `Wolf::Crypt.protected?`
    /`.refuse_protected!`) is a separate AES/ChaCha scheme applied to
    individual `Data/` files' own bytes, independent of whichever container
    (loose or packed) they arrived through -- `WolfTL`'s own
    `WolfDxArcKey.hpp` derives a *DXA* key from a Pro-protected `Game.dat`'s
    bytes, i.e. the container stays plain DXA either way. So `Wolf::Project`
    reads a packed file exactly as it reads a loose one, through the same
    `Wolf.open_envelope`/`Crypt.refuse_protected!` gate every `data.rb`
    parser already calls -- a Pro-protected packed release is refused at
    exactly the place, with exactly the message, a Pro-protected loose one
    already is, with nothing new to build.
- **`Wolf::Project`** (`data.rb`) gets one seam instead of a scattered
  `if packed? ... else ...`: `#initialize` picks a backing store once
  (`@archive` nil for a loose tree, a `DataWolf` for a packed one) and
  `#read(rel)` is the only method that looks at it, stripping the leading
  `"Data/"` every call already passes (DXA's own `EncodeArchiveOneDirectory`
  lists a directory's *children*, not the directory itself, so a real
  archive is expected to be rooted at `Data/`'s own contents, not a `Data/`
  wrapper folder -- see the file header for the reasoning this rests on).
  Every other class in `data.rb` (`GameDat`, `MapTree`, `TileSetData`,
  `Database`, `CommonEvents`, `Map`) already went through `#read` and needed
  no change at all. `Project.project?` recognizes either shape.

## Consequences

- A released, packed WOLF RPG Editor game is now readable the same way a
  loose editor project already was -- closing the gap `docs/TODO.md`'s
  "Packed releases" bullet named.
- **Real-data verification, despite no real `Data.wolf` fixture existing**:
  `scripts/wolf_data_wolf_check.rb` packs the *entire* downloaded sample
  game's `Data/` tree (660 files, ~9 MB, real nested directories) with
  `Wolf::DataWolf.pack`, points a second `Wolf::Project` at the packed copy,
  and asserts the game title, tile size, map tree, tileset count, all three
  databases' type counts, common-event count, and every real map's width,
  height, tile layers and events come back byte-for-byte identical to the
  loose-tree parse of the exact same project -- confirmed green. This is
  still fundamentally a round-trip (this reader's own `.pack` built the
  fixture `Wolf::DataWolf` then read back), not proof of byte-for-byte
  compatibility with a real DxLib-built `Data.wolf` the way
  `scripts/wolf_testbed_check.rb`'s genuine editor output is for the loose-
  tree side -- but it is a much stronger one than a hand-built unit fixture:
  real file names, real nested directory depth, a real project several times
  the size any synthetic test would use, read back through the entire
  `Wolf::Project` parsing pipeline rather than only `Wolf::DataWolf` itself.
- 10 new CRuby/mruby-level unit tests (`mruby-wolf/test/wolf_test.rb`): the
  CRC32 implementation against the textbook check value (independent of
  anything WOLF/DXA-specific), a nested-directory/empty-file/CHUNK-spanning-
  file round trip, auto-detection picking a non-default known key, a
  `no_key` archive, an explicit forced key, a bad header, an unsupported
  version, an unknown key, a compressed header, a compressed entry, and
  `Wolf::Project.project?` recognizing a packed directory.
- **Trade-offs / follow-up.** Two gaps are left exactly where "Decision"
  says, both refused rather than guessed: compressed DXA archives (should
  one ever turn up), and the older v5/v6 container pre-2.281 editor releases
  used. Neither blocks the common case: every 3.x release, including the
  bundled sample game's own 3.724, uses the v8 format this reader implements.
