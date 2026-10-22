# 544. LCF int16 map layers as std::vector<int16_t> in bc2cpp

Date: 2026-10-22

## Status

Proposed. Extends ADR 0541 to LCF fields, which 0541 excluded.

## Context

ADR 0541 sealed int16 arrays only where a proof shows no escape and no
reflection write. It excludes the LCF fields, which escape and take arbitrary
values (ADR 0537, deprecated). The census found no sealed candidates among real
engine arrays, so the proof as written never fires on a real game.

The map layers are the LCF int16 arrays with a hot read path: `Game::Map#@lower`
and `@upper`, from chunks 71 and 72 (`MAP_UNIT/lower_layer`, `upper_layer`,
`int16_array`). The layer ids are read by `Game::Map#tile` on every rendered
cell and by collision checks, and written by the map editor's paint tool.
Measured in the closed build (PR #2602): these two ivars are no longer in the
poison report, so ClassLayout types them as Array. `tile`'s parameter still
reads generically, because parameter class proofs are not fed back into
codegen.

Every interaction with the layer arrays in engine Ruby, checked by grep:

| Operation | Site | Shape |
|---|---|---|
| read | `Game::Map#tile(layer, ...)` via `#lower`/`#upper` | `layer[y * @width + x]` |
| write | `Game::Map#set_tile` via `#set_lower`/`#set_upper` | `layer[i] = tile_id`, unchecked |
| escape | `Game::Map#sync_layers_to_unit` | `@unit[71] = @lower`, then `unit.save_to` |
| read back | none | no reader of `unit[71]` runs after the sync |

The escape is the hard part. `@unit[71] = @lower` stores the same object into
the unit, so after the sync the unit's chunk and `@lower` are aliases. The save
then packs the values through `LCF.pack_int16`, which masks each value to 16
bits. `set_tile` does not check that the value fits, so an out-of-range tile id
is already silently truncated on save today.

## Decision

1. **Owner.** `Game::Map` holds `@lower` and `@upper` as
   `std::vector<int16_t>` members (ADR 0541's struct placement, now opted in
   for an LCF field). They stay in the owner's struct; no `iv_tbl` slot.

2. **Reads.** `tile` and the collision reads index the vector directly with a
   bounds check, and return a Fixnum. Out of bounds returns nil, as `Array#[]`
   does.

3. **Writes, range gate.** `set_tile` stores into the vector only when the
   value is in int16 range. An out-of-range value does not reach the vector: it
   is refused (a raised `RangeError`, not a silent mask). This changes today's
   behavior, so it needs a check that pins the new refusal and a changelog
   entry. The alternative, keeping the mask, would make the vector and the saved
   file agree without a refusal, but it would hide a bad id from the editor.

4. **Escape, copy on save.** `sync_layers_to_unit` boxes each vector into a
   fresh Array and stores that in the unit. The unit never holds the vector, so
   the unit/layer aliasing above disappears. Sound because no reader of
   `unit[71]` runs after the sync, and the save packs values, so a copy writes
   the same bytes.

5. **Reflection.** As ADR 0541 point 4: a read through `instance_variable_get`
   boxes a copy; a write raises. The proof already excludes `instance_variable_set`
   on `Game::Map`.

6. **Gate.** The emitter switch stays off by default (`BC2CPP_LCF_INT16_LAYERS`),
   as the sealed locals were, until the closed build and the runtime checks pass
   with it on. Default output does not change while it is off.

## Consequences

- Layer reads become direct loads. That is the win this ADR is for; it is not
  yet measured on a rendering benchmark.
- Map editing now refuses an out-of-range tile id. A user who painted such an
  id before would have had it truncated on save. The refusal is a visible
  behavior change and goes in the changelog as one.
- The unit's `[71]` and `@lower` stop being the same object. Nothing depends on
  that today; a future reader of the unit's raw chunk after a sync would
  observe a copy.
- `Scene::Map` and the chipset helpers call `#lower`/`#upper` and get a Fixnum
  from the vector exactly as from the Array. Their call sites do not change.

## Staging

1. Pin the current behavior with a fixture: a layer read, a write, the sync, and
   a save round trip, all on the Array representation. This is the oracle.
2. Add the range refusal to `set_tile` (its own change, with the changelog
   entry), independent of storage.
3. Add the vector placement and the box-on-escape behind the switch. The
   fixture from step 1 must give the same bytes on save.
4. Turn the switch on in CI's closed build and compare the poison report and the
   generated `tile`.

## Open questions

- Whether the reflection refusal is a `TypeError` or a silent copy-on-write.
  Same open question as 0541; the answer should match.
- Whether `Game::Map#dup` or Marshal needs the vector copied or re-derived from
  the boxed form. Both currently go through reflection.
- Whether to refuse out-of-range ids at the editor (`Scene::MapViewer`) instead
  of in `set_tile`. Refusing in `set_tile` covers every writer; the editor is
  the only one today.
