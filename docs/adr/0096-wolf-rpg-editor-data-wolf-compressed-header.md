# 96. WOLF RPG Editor: `Data.wolf` compressed header tables, and a real-game finding

Date: 2026-09-07

## Status

Accepted

## Context

ADR 0093 shipped `Wolf::DataWolf`, the `Data.wolf` packed-release reader, but
could not test it against a real released game -- no freely-redistributable
one was known at the time, so it was validated only by a synthetic-fixture
round trip and by re-packing the (loose-tree) bundled sample game with its
own `.pack` and reading that back (`scripts/wolf_data_wolf_check.rb`). That
ADR's own "Scope" section flagged this explicitly: DXA's header-table
compression was left unimplemented because "there is no `Data.wolf` fixture
in this repo to confirm real releases actually exercise that path", with a
stated *expectation* (not a confirmed fact) that real archives skip it.

This session found and downloaded 「或る魔女について」("About a Certain
Witch") v1.03 by Ryuu, a short freeware WOLF RPG Editor game hosted on
[freem.ne.jp](https://www.freem.ne.jp/) (a well-known Japanese freeware
distribution site; the actual file is served from `fgamearchives.com`, the
same host `scripts/download-prayforyou.bash`/`download-killer-knights.bash`
already use for other engines' real test fixtures) -- the first real,
genuinely released `Data.wolf` this reader has ever been pointed at.

Pointing `Wolf::DataWolf.open` at its `Data.wolf` immediately raised the
"header table is compressed" refusal ADR 0093 anticipated as a possibility:
the expectation was wrong, at least for this release. Two more things,
however, turned out to also be wrong for this specific archive after
implementing decompression (see "Consequences"):

## Decision

- **Ported DxLib's own header-table decompression**, cross-validated against
  the exact same vendored reference ADR 0093 already used
  (`/home/user/3rdref/WolfDec`'s `3rdParty/Huffman.cpp`/`DXArchive.cpp`):
  - `Wolf::DataWolf.huffman_decode` ports `Huffman_Decode` -- rebuilds the
    511-node Huffman tree from the stored per-byte-value frequency table (256
    signed differences from the previous entry), then walks it root-to-leaf
    one output byte at a time. Skips `Huffman_Decode`'s own 9-bit
    `NodeIndexTable` lookup (a pure decode-speed optimization in the original
    C++) in favor of a plain bit-by-bit walk -- both visit the same tree
    edges for the same output.
  - `Wolf::DataWolf.dxa_lz_decode` ports `DXArchive::Decode`, a custom
    LZ77-family decoder distinct from `Wolf::LZ4` (the content-layer codec):
    literal bytes, a keycode-escape for the literal byte that collides with
    the stream's own escape value, and back-references whose length/distance
    are packed into 1-3 trailing bytes -- including the self-overlapping-copy
    case (distance shorter than run length) via the same doubling loop the
    original uses rather than a plain `memcpy` (which would corrupt an
    overlapping copy).
  - `Wolf::DataWolf#initialize`/`#find_key` now read the compressed blob (name
    table start to EOF, matching `OpenArchiveFile`'s own `HuffHeadSize =
    FileSize - ftell(...)`), decrypt it the same way the uncompressed path
    already did, then Huffman-decode then LZ-decode (that exact order --
    confirmed from `DXArchive.cpp`'s own header-write path, `Encode` then
    `Huffman_Encode`) before handing the result to the existing
    `#plausible?`/`#walk_directory`. A cheap pre-decode size gate
    (`.huffman_decoded_size`, a handful of bit reads) rejects a wrong
    `KNOWN_KEYS` candidate before ever attempting a full decode of noise --
    important because a wrong key can turn the stream's own claimed sizes
    into an arbitrary 64-bit value.
- **Cross-validation methodology**: rather than only unit-testing the port
  against itself, this session compiled the vendored `Huffman_Encode`/
  `DXArchive::Encode` (the untouched reference C++, not a reimplementation)
  against known plaintext via a throwaway g++ harness, and fed the *real*
  compressed output into the Ruby port -- round-tripping literal runs, the
  keycode-escape path, non-overlapping and self-overlapping back-references,
  all-same-byte and single-byte degenerate Huffman trees, and a full
  Huffman(LZ(table)) pipeline matching the real header-table encode order.
  This caught a real bug before it shipped: the compressed *payload*'s bits
  are packed LSB-first starting at a fresh byte boundary right after the
  header fields, not a continuation of the header's own MSB-first
  `BIT_STREAM` bit cursor -- an easy mistake the file's own two different bit
  conventions invite, only caught by decoding real encoder output rather than
  hand-traced bytes. Three of these fixtures (a small Huffman one, two LZ
  ones, one full-archive one) are now `mruby-wolf/test/wolf_test.rb`'s own
  regression tests, replacing the old "rejects a compressed header table"
  test with "reads a real compressed (Huffman+LZ) header table".
- **A clear, named refusal for a header whose own `DARC_HEAD` fields are
  bogus** (`name_table_start` implausibly large) rather than letting a raw
  `Errno::EINVAL` leak from seeking to nonsense -- needed for the finding
  below, where the "About a Certain Witch" archive's `DARC_HEAD` fields past
  `HeadSize` are not the plain bytes `WolfDec`'s own reader (and this one)
  assumed every real archive has.

## Consequences

- Any `Data.wolf` whose header table is Huffman+LZ-compressed (the case ADR
  0093 could only guess at) is now readable, cross-validated against the real
  DxLib encoder rather than only self-consistent with this reader's own
  decode.
- **This specific real game still cannot be opened**, and the reason is a
  separate, deeper gap than table compression: after decompression support
  landed, "About a Certain Witch"'s `DARC_HEAD` fields past `HeadSize`
  (`DataStartAddress`, `FileNameTableStartAddress`, `FileTableStartAddress`,
  `DirectoryTableStartAddress`) come back as implausibly huge 64-bit values --
  and, per this reader's and WolfDec's own shared assumption, those fields are
  supposed to need no key at all. **This is not isolated to one game**: the
  two other freem.ne.jp candidates found alongside it ("He_reitis",
  「グリーンフェアリーの緑化活動」, different creators, different file sizes)
  were downloaded and tried too, and hit the exact same wall -- strong
  evidence this is now the standard shape of a current WOLF RPG Editor
  release, not a one-off. Its shipped `Game.exe` bundles debug strings naming
  `DxArchive_WOLF_MOD.cpp`/`DxArchive_WOLF_MOD_security.cpp` -- a
  WOLF-RPG-Editor-specific *modified* DxArchive.
  - **What this session ruled out, with a concrete lead that does not pan
    out.** `Flags`' own upper 16 bits (`Flags >> 16`) turn out to be a real,
    meaningful "cryptVersion" selector -- confirmed via the actively-
    maintained [UberWolf](https://github.com/Sinflower/UberWolf) project's
    current `WolfDec.cpp` (`getCryptVersion`), fetched and read directly
    (not through a lossy summarizer) via `raw.githubusercontent.com`. All
    three real games here decode that field to exactly `350`, matching a
    named `"Wolf RPG v3.50"` entry (with its own known 51-byte static key)
    in UberWolf's own current `DEFAULT_CRYPT_MODES` table -- not a
    coincidence across three independent files, and confirmation that
    `HeadSize`/`Flags`/`CharCodeFormat` genuinely are plain, exactly as
    assumed. `cryptVersion` 350 is *not* one of the values (`1000`, `0xC8`,
    `1010`) UberWolf's own `WolfPro.cpp` treats as needing its separate
    Game.dat-derived-key "Pro" path (that path, and its `WolfX` crack module,
    turned out to be for a *different* problem -- individual files bearing
    their own `"WOLFX"` 5-byte magic header, not the `Data.wolf` container
    itself). By UberWolf's own code, `cryptVersion` 350 is a plain, ordinary,
    already-named key, and `DXArchive::OpenArchiveFile` -- confirmed
    byte-identical between the original vendored WolfDec source and
    UberWolf's own current copy -- never applies any key to `DARC_HEAD`'s
    address fields for *any* `cryptVersion`. None of that explains why those
    four fields come out as noise here. Since a key cannot fix a field the
    reference implementation never keys in the first place, the "v3.50" key
    was not added to `KNOWN_KEYS` -- it would be dead code with no way to
    verify it does anything.
  - **What remains unexplained**, precisely scoped for whoever picks this up
    next: something about how a current WOLF RPG Editor release actually
    produces these four `DARC_HEAD` fields differs from every available
    public reference implementation (original WolfDec, and UberWolf's own
    current fork) -- despite the rest of the same 64-byte header
    (`Head`/`Version`/`HeadSize`/`CharCodeFormat`/`Flags`) matching that
    reference exactly. This looks like an undocumented change specific to
    `DxArchive_WOLF_MOD_security.cpp`, which no public source tree vendors --
    not something guessable from the outside without either that source or a
    live binary to test candidate transforms against (WOLF RPG Editor itself
    is Windows-only; not run in this session). Porting a guess without a way
    to verify it would risk exactly the "silently wrong crypto" failure mode
    this project's WOLF work has consistently refused to ship (see ADR 0095's
    own methodology) -- so this stays a named, precisely-scoped gap rather
    than a speculative fix. `Wolf::DataWolf.new` reports it with a clear,
    specific error instead of a raw IO exception or (worse) silently wrong
    data.
- **What this means for "can this reader boot a real game"**: of three
  independent, real, freely-distributable current WOLF RPG Editor releases
  tried this session, all three hit this same wall -- packed releases are
  very likely uniformly blocked on it now, while a loose (unpacked,
  in-editor-working-tree) real project remains unaffected (this gap is
  specific to `Data.wolf`'s container, not the data format itself). This is a
  materially better-understood blocker than the "permanently out of reach"
  framing this session's own earlier (later corrected, see ADR 0095)
  assessment of Pro-protected data used: the exact field, the exact
  `cryptVersion` value, and the exact reference code that fails to explain it
  are all pinned down -- what's missing is the one piece of source or a live
  binary that isn't publicly available to verify a fix against.
