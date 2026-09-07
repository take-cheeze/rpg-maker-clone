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
  (`DataStartAddress`, `FileNameTableStartAddress`, ..., `Flags` itself) come
  back as noise under every `KNOWN_KEYS` candidate -- and, per this reader's
  and WolfDec's own shared assumption, `DARC_HEAD` is supposed to need no key
  at all. Its shipped `Game.exe` bundles debug strings naming
  `DxArchive_WOLF_MOD.cpp`/`DxArchive_WOLF_MOD_security.cpp` -- a
  WOLF-RPG-Editor-specific *modified* DxArchive, not the stock DxLib one
  `WolfDec`'s vendored source (and so this reader) models. Cross-referencing
  the actively-maintained [UberWolf](https://github.com/Sinflower/UberWolf)
  project (WolfDec's own successor) confirms this is real and already known
  in the community: its `UberWolfLib/WolfX` module exists specifically to
  defeat this newer scheme, via a large precomputed magic-value lookup table
  (`WolfXDecryptCollection`, indexed by up to 10,000 x 1,000,000 candidate
  values, validated by an embedded checksum) built from extensive reverse
  engineering -- not a documented algorithm this session could cross-validate
  the way `Huffman_Decode`/`DXArchive::Decode` above were. Porting it without
  being able to verify it against a compiled reference would risk exactly the
  "silently wrong crypto" failure mode this project's own WOLF work has
  consistently refused to ship (see ADR 0095's own methodology) -- so it is
  named here as a concrete, currently-out-of-scope gap rather than attempted.
  `Wolf::DataWolf.new` reports this case with a clear, specific error instead
  of a raw IO exception or (worse) silently wrong data.
- **What this means for "can this reader boot a real game"**: the two other
  freem.ne.jp candidates found alongside this one ("He_reitis",
  「グリーンフェアリーの緑化活動」) were not tried and may or may not hit the
  same WolfX-modified archiver -- newer editor releases plausibly all ship
  it, in which case *any* packed real release needs the same unported WolfX
  scheme, while a loose (unpacked, in-editor-working-tree) real project would
  be unaffected (this gap is specific to `Data.wolf`, not the data format
  itself). This is a materially different, better-understood blocker than
  the "permanently out of reach" framing this session's own earlier (later
  corrected, see ADR 0095) assessment of Pro-protected data used: there is a
  known, actively-maintained reference implementation, just not one this
  session could responsibly port from a lossy summary alone.
