# 18. Write LcfSaveData back out: an LCF serializer verified against real saves

Date: 2026-08-04

## Status

Accepted

## Context

ADR 0009-0017 built the `LcfSaveData` **read** path: the `SAVE_DATA` schema
(`mruby-lcf/mrblib/schema.rb`), the chunk/BER decoders (`mruby-lcf/mrblib/lcf.rb`),
and validation against genuine RPG Maker 2000 (Nepheshel) and 2003
(mtf-meido-action) saves via `scripts/lcf_save_check.rb`. `Game::State.from_lsd`
loads a parsed save into the running game, so **Continue** can already resume a
real `.lsd`.

The write path did not exist. `mruby-lcf` was parse-only, and the in-game **Save**
command still persists a portable `Marshal` dump of `Game::State`, not the real
`.lsd` format (see `docs/TODO.md`, "Save & Continue"). Before the runtime can
save in the genuine format, the LCF layer needs to be able to turn a parsed
(or edited) save structure back into byte-faithful `LcfSaveData` -- and that
serializer has to be *proven* against real files, exactly as the reader was, or
a subtly wrong writer would produce saves the real editor/EasyRPG rejects.

The key enabler is already in the reader: `Array1D`/`Array2D` retain every
chunk's **raw payload bytes** (`@data[idx] = s.read len`) for *every* chunk,
documented or not -- decoding is lazy, per field, on access. The still
-undocumented top-level chunks (102, 112, 200) are therefore held verbatim, not
discarded. So a faithful copy needs no understanding of those chunks and no
field-level re-encoding: re-emit the retained raw bytes with correct framing.

Two framing details had to be pinned down against the real fixtures:

- **Chunk order.** Both real saves store their top-level chunks in strictly
  ascending id order, so emitting `@data` by ascending index reproduces it.
- **Top-level terminator.** An `Array1D` embedded in an `Array2D` is closed by a
  `write_ber(0)` terminator (entries carry no length prefix, so the reader scans
  until id 0). The **top level of a save file has no such terminator** -- the
  chunk list runs to EOF, and the reader stops on `eof?`. Emitting a terminator
  there adds one spurious trailing byte; both real fixtures confirm its absence.

## Decision

- **Add the inverse primitives to `mruby-lcf/mrblib/lcf.rb`:** `LCF.write_ber`
  (the exact inverse of `read_ber`, including the 32-bit two's-complement form
  so negatives round-trip -- `-1` -> `8f ff ff ff 7f`, as RPG_RT writes), plus
  `LCF.encode` / `LCF.pack_int32` for the scalar and simple-array field types a
  save actually re-authors (`:int`, `:bool`, `:uint8`, `:int8_array`,
  `:bool_array`, `:int32_array`, `:string`). Packed command / `:double` / `:Tree`
  fields are intentionally not re-encoded from decoded values; they are preserved
  as their original raw bytes.
- **Serialize structurally:** `Array1D#to_lcf(terminate = true)` re-emits present
  chunks ascending as `write_ber(id) + write_ber(len) + bytes` (raw bytes for
  unedited chunks; a nested object's own `#to_lcf` otherwise), with the
  terminator suppressible; `Array2D#to_lcf` writes the count-prefixed entry list;
  `File#to_lcf` prefixes the BER-length header and serializes the root
  Array1D **without** a top-level terminator. `File#save_to(path)` writes it.
- **Edit in place:** `Array1D#[]=` encodes a Ruby value through the field's schema
  type and stores it as that chunk's raw bytes, so a parsed save can be modified
  (e.g. hero position, save counter) and written back.
- **String encoding mirrors the reader.** As `cp932_to_utf8` (uni-algo) decodes
  on read, `LCF.utf8_to_cp932` encodes `:string` fields on write; the CRuby
  harnesses provide a Windows-31J stand-in, symmetric with the existing read stub.
- **Portability.** Byte buffers use `String.new` (ASCII-8BIT under CRuby, a plain
  buffer under mruby) and an `LCF.binstr` coercion that is a no-op under mruby
  (no `Encoding`); iteration uses `each_with_index` (blockless enumerators and
  `each_index` are avoided, matching the reader's existing idiom).

## Consequences

- **Byte-exact round-trip on real saves.** `scripts/lcf_save_roundtrip.rb` parses
  a genuine `.lsd`, re-serializes it, and asserts the bytes equal the original --
  verified against both the RPG2000 (Nepheshel, 17797 B) and RPG2003
  (mtf-meido-action, 11132 B) fixtures. Because the undocumented chunks are
  copied verbatim, this proves the *framing* (BER lengths, ascending order, no
  top-level terminator) is reproduced bit for bit without needing those chunks
  documented.
- **Edits survive a write/reload.** The same harness bumps the hero position and
  the system save counter through the schema, writes, and re-parses -- the new
  values load back and an untouched chunk (the title block) is byte-identical,
  proving `LCF.encode` / `#[]=` produce a genuinely re-loadable save.
- **CI coverage is synthetic-but-real.** The real `.lsd` fixtures are generated
  under wine and not vendored (`data/` is git-ignored), so -- like
  `lcf_save_check.rb` -- the round-trip harness runs on demand
  (`scripts/gen-lcf-save-wine.bash` now runs it after generating a save), not in
  CI. The writer's CI guard is `mruby-lcf/test/lcf_test.rb`, which exercises
  `write_ber` against the reference encoder, `Array1D`/`Array2D#to_lcf`,
  `Array1D#[]=`, and a whole-file `SaveData#to_lcf` round-trip on self-consistent
  synthetic data run by the native `test` target.
- **Save & Continue can now target the real format.** The remaining work is a
  `Game::State#to_lsd` that builds a `SAVE_DATA` structure from live game state
  and calls `SaveData#save_to`, replacing the portable `Marshal` save -- a
  runtime-side change that this LCF serializer makes possible. Until then the
  writer is exercised by the round-trip harness and unit tests.
- **The writer stays honest about what it can re-encode.** Packed event/move
  command lists, doubles (the save timestamp) and tree chunks are round-tripped
  as raw bytes but not yet re-encodable from decoded values; a future change that
  needs to author those from scratch must add their encoders (and prove them the
  same way).

## Addendum: the "no top-level terminator" rule does not generalize to `.lmu`

The "no terminator" finding above was proven only against `.lsd` (`SaveData`),
but `File#to_lcf` applied `terminate = false` unconditionally to every
subclass -- `Database` (`.ldb`) too, which turned out to share the rule (a
genuine `RPG_RT.ldb` round-trips byte-exact with no terminator), but also
`MapUnit` (`.lmu`), which does not: a real `.lmu` carries a trailing `0x00`
root terminator, confirmed by round-tripping genuine Nepheshel `Map*.lmu`
files (each came out exactly one byte short without it, byte-identical with
it appended) and, at runtime, a genuine RPG_RT.exe hanging on a black screen
loading a map file we wrote without that byte. `File` now exposes a
`#terminate_root?` predicate (default `false`, matching `.lsd`/`.ldb`) that
`MapUnit` overrides to `true`. See the dated entry in `docs/TODO.md`'s
Tooling section.
