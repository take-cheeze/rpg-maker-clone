# 20. Bring the .lsd export to near-parity with the Marshal save

Date: 2026-08-04

## Status

Accepted

## Context

ADR 0019 gave `Game::State#to_lsd` a writer that exports four save chunks
(system 101, hero 104, actors 108, inventory 109) as the exact inverse of
`from_lsd`, and closed by naming what promoting `.lsd` to the *primary* save
would take: modelling the fields the `Marshal` dump carries but the export drops
— the timer, message config, current/memorized BGM, actor name/title/sprite
overrides and the menu/save/teleport/escape access flags — plus the title chunk
(100), which needs `:double` timestamp encoding for the save-slot menu. This ADR
narrows that gap to almost nothing.

Two facts shaped the scope:

- **Most of those fields already exist in the `SAVE_SYSTEM` / `SAVE_TITLE` /
  `SAVE_MOVABLE` schema**, they were simply never written or read by the runtime.
  The message config maps to SaveSystem 41–54, the BGM to 75 / 78, the
  player-transparent flag to 55, the access flags to 121–124; the leader's on-map
  sprite is the hero chunk's CharSet (104 / 73 / 75); the title chunk (100) holds
  the leader's name / level / HP and the party FaceSets. These mappings were
  confirmed field-for-field against liblcf's `RPG::SaveSystem`.
- **The game timer has no home in the save's system chunk.** liblcf's
  `SaveSystem` carries a `frame_count` but no timer field, so there is no
  documented chunk id to write the countdown into. Inventing one would violate
  the codebase's rule that every schema field cites a source (a wiki page or a
  real-save decode), so the timer is deliberately left out rather than guessed.

The one encoder still missing was `:double`: `LCF.encode` handled every scalar
and array type a save needs except the title timestamp.

## Decision

- **`Game::State#to_lsd` / `from_lsd` round-trip the extended fields.** The
  export now also writes, and the reader restores: the message-window
  configuration (SaveSystem 41–54, with the documented sign conventions — 41
  transparency is 0/1, 43 prevent-overlap is the inverse of our "pinned" flag, 53
  face side is 0 left / 1 right), the current and memorized BGM (75 / 78, via a
  nested BGM chunk built from our `{ name:, volume:, tempo: }` hash), the
  player-transparent flag (55), the access flags (121–124, only overriding the
  constructor default when physically present so a foreign save keeps our
  defaults), the leader's CharSet override in the hero chunk (104), and the title
  chunk (100): the timestamp, the leader's name / level / current HP and up to
  four party FaceSets. The leader's display name is restored from the title
  chunk, so a Change Actor Name on the leader survives.
- **Add the `:double` encoder.** `LCF.pack_double` builds the 8 little-endian
  IEEE-754 bytes byte-wise from the sign / biased exponent / 52-bit mantissa —
  the inverse of `unpack_double` — so it needs neither the `'E'` pack directive
  nor a full 64-bit integer (mruby's `Integer` is 63-bit; the assembly never
  forms a value above 2**52). `LCF.encode` gains a `:double` branch. It is exact
  over the non-negative finite domain a timestamp occupies, which is also the
  domain `unpack_double`'s 63-bit assembly reproduces.
- **Keep the Marshal save primary.** With the timer and non-leader name/title
  overrides still outside the `.lsd`, `save_game` continues to write the Marshal
  dump as authoritative and export the (now near-parity) `.lsd` beside it;
  Continue still prefers the Marshal save and falls back to a `.lsd` only when
  there is none.

## Consequences

- **The `.lsd` we write is now readable as a real save with the party on the
  file screen.** A genuine RPG_RT / EasyRPG file-select shows the leader's name,
  level, HP and the party portraits from the title chunk we emit.
- **The round-trip guard grew.** `scripts/rpg2k_save_load_check.rb` mutates every
  new field (message config, BGM, transparency, access flags, leader sprite /
  name) to a non-default value before `state -> to_lsd -> from_lsd` and asserts
  each survives, against the real Nepheshel (2000) and mtf-meido-action (2003)
  saves; it also gained a `utf8_to_cp932` shim, since the writer now emits string
  fields the earlier all-numeric export never did. The CI gate,
  `mruby-lcf/test/lcf_test.rb`, adds a `pack_double` / `:double` round-trip
  (checked against the 1.5 reference bytes and `unpack_double`) and a
  from-scratch save that writes the title chunk plus the extended system fields
  and reads them straight back.
- **The remaining gap to a `.lsd`-primary save is two fields.** The game timer
  (blocked on a documented SaveSystem chunk id) and per-actor name/title
  overrides for non-leader members. Both are tracked in `docs/TODO.md`.
- **mruby-core discipline carries forward.** `pack_double` uses only core
  arithmetic and `Array#pack('C*')`, forming no value wider than mruby's 63-bit
  integer, consistent with the ADR 0018/0019 constraint.
