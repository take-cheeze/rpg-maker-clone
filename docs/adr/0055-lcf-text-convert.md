# 55. A schema-checked binary <-> text converter for LCF project files

Date: 2026-08-19

## Status

Accepted

## Context

The debug tooling added under `mruby-rpg2k/mrblib/scene/` so far (the F9
debug menu's Switch/Variable pages, the Map viewer and its Select-mode
teleport) is deliberately read-only against the on-disk project: it edits
`Game::State` for the current session and never touches a `.ldb`/`.lmu` file,
so it cannot collide with a real RPG Maker project or its own editor.

The next piece of debug/editor tooling is different in kind: editing a
project's *parameters* (actor stats, item/skill tables, map dimensions,
event pages, ...) directly, meant to persist. Doing that field-by-field
inside the engine's own 320x240 window — the way the existing Variable
editor's signed-number keypad works — does not scale to a whole database;
a real text editor already does that job well. The map itself is the
exception (tile painting has no good text form, hence the Map viewer/editor
staying in-engine and visual), but everything else is naturally
text-editable *if* there is a safe way to get it into and back out of text.

The risk is the same one that shaped every debug-tool decision so far: RPG
Maker 2000/2003's own `.ldb`/`.lmu`/`.lmt` format (LCF, a BER-length-prefixed
chunk stream) is the *original* project format, not something this project
invented. A converter that reads and writes it is not introducing a
competing format — but a broken writer, or one that silently drops or
misinterprets a field, absolutely could corrupt a real project. "Schema
checking" — validating an edited text file against the same field
definitions the runtime itself reads before ever touching the binary
encoder — is what keeps that risk bounded.

The binary codec itself did not need to be built new. `mruby-lcf/mrblib/
lcf.rb`'s `Array1D#to_lcf` / `Array2D#to_lcf` / `File#to_lcf` already
round-trip a real save (`.lsd`) byte-exact and support field-level edits
through `LCF.encode`, proven by `scripts/lcf_save_roundtrip.rb` — the format
is shared across every LCF file type (only the schema, from `mruby-lcf/
mrblib/schema.rb`, differs), so that machinery generalises to `.ldb`/`.lmu`/
`.lsd` directly. `LCF.encode` was missing two cases though: the `:event` and
`:move_commands` container types (event-page command lists and move routes)
had readers (`parse_event_commands`/`parse_move_commands`) but no writers —
edits to those specific fields could not be re-encoded before this ADR. Both
scalar tables *and* command lists needed to be editable for the converter to
be more than a database-only tool, since event pages carry both.

## Decision

Two changes:

1. **`LCF.encode_event_commands` / `LCF.encode_move_commands`** (`mruby-lcf/
   mrblib/lcf.rb`), the exact inverses of the existing
   `parse_event_commands`/`parse_move_commands` readers, wired into
   `LCF.encode`'s `:event`/`:move_commands` cases. Covered by new assertions
   in `mruby-lcf/test/lcf_test.rb` alongside the existing parser tests,
   checked both for byte-exact inversion of a hand-built blob and for
   round-tripping through `LCF.encode`/`.parse_*` together.

2. **`scripts/lcf_text_convert.rb`**, a CLI tool with three subcommands:
   - `to_text IN.ldb|lmu|lmt|lsd OUT.yml` — reads the binary file (its LCF
     class picked by extension) and walks it with `schema.rb`'s field names,
     not raw chunk ids, into a YAML document. Only chunks actually *present*
     in the file are emitted (`Array1D#key?`), preserving the
     absent-vs-default distinction the runtime itself cares about (chunk 23/
     24 in a project that never named a switch, for one).
   - `to_binary IN.yml OUT.ldb|lmu|lsd` — the inverse: validates the YAML
     against the schema (unknown field names, wrong scalar types, malformed
     event/move-command entries — collected and reported *all at once*, not
     one-fix-per-run) and only then builds fresh `Array1D`/`Array2D` objects
     through `[]=` (which itself re-encodes via `LCF.encode`) and writes them
     with `File#save_to`.
   - `check IN.yml` — the same validation pass with no write, for iterating
     on an edit before committing it.

   The YAML carries its own `type:` field (`database`/`map_unit`/
   `save_data`/`map_tree`) rather than trusting a filename extension, so
   `to_binary`'s output path doesn't have to match the source's original
   extension.

   `.lmt` (the map tree) is text-exportable but **not** binary-writable yet:
   its root is a multi-section file (`LCF::Sections`, three parts — map
   properties, tree order, initial party/vehicle position) and `File#to_lcf`
   itself already raises `'section-based file serialization not
   implemented'` for that shape. `to_binary`/`check` report this plainly as
   a validation error rather than attempting an unproven encoder.

   `scripts/lcf_text_convert_check.rb` proves the whole pipeline against
   synthetic fixtures built the same from-scratch-`Array1D` way `mruby-lcf/
   test/lcf_test.rb` does (no real test-bed project needed): byte-exact
   round-trip for both `map_unit` and `database` — including a `move_route`
   and an event-command page, so the two new encoders are covered
   end-to-end, not just at the unit level — a semantic edit surviving a
   reload with an untouched sibling field unaffected, schema-check rejection
   of an unknown field and a type mismatch (reported together), and the
   `.lmt` write-guard.

## Consequences

- Any RPG2000/2003 project's database and map-unit files can now be edited
  as text (with real validation, not just "well-formed YAML") and written
  back to the exact binary format `RPG_RT.exe` and the real editor read —
  this project still speaks only the original format, so nothing about a
  project edited this way is any less a genuine RPG Maker project.
- `.lsd` saves gain a text-editing path as a side effect of the same tool
  (same schema-driven machinery, `save_data` was already the proven case).
- `.lmt` (map tree) is read/export only until a `Sections`/multi-section
  writer exists — flagged, not silently broken. Follow-up work if a text
  editor for the map tree (parent/child map organisation, per-map BGM/
  teleport-escape-save flags) turns out to be wanted.
- Event-page command lists and move routes are now genuinely re-encodable,
  which is also the foundation the roadmapped in-engine event-command
  browser (guarding against a text edit producing a structurally "valid" but
  logically broken If/Else/Loop nesting) will need regardless of whether
  editing happens through this text tool or that future browser.
- The tool is offline (a `scripts/*.rb` CLI, loaded under CRuby exactly like
  `lcf_save_roundtrip.rb`/`lcf_testbed_check.rb` already are) rather than
  in-engine: no new runtime dependency, no game-loop cost, and it needs no
  native build to run or test.
