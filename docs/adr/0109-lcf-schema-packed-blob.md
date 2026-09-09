# 109. Replace mruby-lcf's schema.rb with a packed binary blob + decoder

Date: 2026-09-09

## Status

Accepted

## Context

`mruby-lcf/mrblib/schema.rb` is ~1,150 field descriptors (name, type,
default, sometimes an `order:` array or nested `elements:`) covering every
RPG2000/2003 chunk format, written as nested Ruby Hash literals. Real
`mrbc -g` compiles: 45,293 bytes -- the single largest file in the gem,
bigger than the actual binary-format reader (`lcf.rb`, 16,274 bytes) by
nearly 3x, for data that is pure declaration, not logic: mruby's Hash-
literal bytecode is a `OP_LOADSYM`/`OP_STRING`/`OP_HASH_PUSH` sequence
*per field*, so flash cost grows linearly with schema size no matter how
repetitive the shape.

ADR 0099 already found (and schema.rb's own `elements_of` comment records)
that eagerly building all ~930 of DATABASE's field descriptors as live
Hash/Symbol objects at once raised a real `NoMemoryError` on the Wio's
192 KB SRAM -- fixed by wrapping each record type's `elements:` in a
`-> { {...} }` block, resolved and cached only on first access. Any change
to how this data is stored has to preserve that split exactly, not just
shrink the file.

## Decision

**`gen_schema_blob.rb`** (new, checked in): a CRuby generator that `load`s
the real `mrblib/schema.rb` -- unchanged, and staying the single source of
truth every `scripts/*_check.rb` script still `load`s directly -- walks
every constant, and serializes the *resolved field data* (not the Ruby
source) into a compact packed binary blob:

- A string table (every distinct field/order name, deduplicated).
- A section table (each `id => field` Hash schema.rb defines, whether a
  bare top-level constant like `COMMON_EVENT`/`SE` or one of DATABASE's
  per-record-type tables), each entry a fixed shape: name index, a 1-byte
  type tag (13 distinct type symbols), a flags byte, a 1-byte default tag
  (real survey: defaults are always nil, an integer, `''`, `true`/`false`,
  `[]`, `0.0`/`100.0`, or one of exactly two callables --
  `LCF.level_max`/`LCF.exp_default` -- so nine fixed tags cover every case
  in the schema with no free-form payload needed except the integer one).
- A top-level table mapping each original constant name back to a section
  (or, for `DATABASE`/`SAVE_DATA`/`MAP_UNIT`, a single field record used
  directly as a whole file's root schema) -- eager or lazy exactly as
  schema.rb itself declared it, so the ADR 99 laziness boundary is
  reproduced byte-for-byte, not just approximated.

A small, constant-size, portable (mruby- *and* CRuby-compatible, though
only mruby ever loads it) decoder module is emitted alongside the blob:
plain `String#getbyte`/`#byteslice` reads, no native code, no StringIO.
Its cost does not grow with schema size -- unlike the Hash literals it
replaces.

**Verified byte-for-byte behaviorally identical**, not just "looks similar":
a comparison script canonicalizes both the original schema.rb's live data
and the generated blob's decoded data (recursively resolving every lazy
`:elements`, calling every callable `:default`) into a deterministic, sorted
dump, run as two separate CRuby processes and diffed. The only difference
found was the schema's `enums:` metadata (confirmed, by grep, never read
anywhere in the codebase -- dropped as genuine dead weight, not an
oversight). Both real object-identity-sharing cases the original code
relies on (`elements: SE` and `elements: LEARNING` each referenced from more
than one place, expected to be the *same* Hash object -- schema.rb's own
`elements_of` comment explains why) were also confirmed preserved.

**Wired into `mruby-lcf/mrbgem.rake`**: `schema.rb` is dropped from
`spec.rbfiles` for the actual mruby build; the generated blob (built into
`build_dir` via a `file` task, the same pattern `cp932.cc`/`shinonome.cxx`
already use) takes its place. `scripts/*_check.rb` are untouched -- they
`load` `mrblib/schema.rb` by path directly, never through `spec.rbfiles`.

### What was measured

| | bytes |
| --- | --- |
| schema.rb, compiled (`mrbc -g`, real) | 45,293 |
| generated blob file, compiled (`mrbc -g`, real) | 23,878 |

A real relink, `env:wio_rgss_boot`, on top of the current default (non-font-
subsetted) wio state:

| state | FLASH overflow |
| --- | --- |
| before | 1,276,188 |
| + schema blob | 1,260,564 |

**15,624 bytes recovered** on a real link -- less than the isolated-compile
delta (21,415) because `--gc-sections` was already partially pruning the
original schema.rb's own dead branches in a full link; the isolated number
overstates what any single file change buys once linked. This ADR reports
the real, linked number as the one that matters.

Two real bugs surfaced only by actually running the generated file through
a genuine mruby interpreter (not just the CRuby-side comparison above),
both since fixed: mruby's `String` has no `#b` (CRuby's force-binary-
encoding method the blob's own string literal was needlessly calling --
mruby strings are raw bytes already, nothing to force), and mruby's
default gem set has no `Module#private_class_method` (dropped from the
decoder; nothing outside the module called the method it was hiding
anyway). Both would have compiled fine and only broken at gem-load time,
which is exactly why the host-side proof rebuilt from ADR 108's own native,
single-format `libmruby.a` and re-ran a real mruby program against it,
rather than trusting the CRuby comparison alone.

## Consequences

- `mruby-lcf/mrblib/schema.rb` keeps being the thing anyone reads or edits
  to change the schema -- this generator only changes what the *mruby
  build* ships, never the source of truth or the CRuby-checked behavior.
- Any future schema.rb edit needs no changes to `gen_schema_blob.rb` itself
  unless it introduces a genuinely new *shape* this generator doesn't yet
  handle (a new field type, a third kind of callable default, a field
  `:default` that isn't one of the nine fixed shapes surveyed here) -- the
  generator raises loudly (`raise "unknown type: ..."` etc.) rather than
  silently mis-encoding one, so a real gap surfaces at generation time, not
  as a silent runtime divergence.
- The dropped `enums:` metadata was pure documentation with no live reader;
  if a future feature wants it back (e.g. a debug data browser rendering
  symbolic enum names), it needs re-adding to both schema.rb and the
  generator's field encoding -- not lost, just no longer free-riding on
  data nothing used.
