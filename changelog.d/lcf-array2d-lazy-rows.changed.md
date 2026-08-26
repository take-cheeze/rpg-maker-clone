- **`LCF::Array2D` decodes rows lazily instead of building one `Array1D`
  object per row the instant a table opens.** Every `.lmt` map-properties
  table (one row per map in the project) and every `.ldb` database table
  (items/actors/skills/enemies/troops/animations/common_events/...) used to
  pay for a full row of decoded objects up front, even though a session only
  ever touches the current map's tree-ancestry and a fraction of database
  rows. Table-open now only scans each row's chunk stream to capture its raw
  byte span (seeking over payloads instead of reading them); `#[]`/`#each`
  decode a row into an `Array1D` on first actual access and cache it in
  place, the same trick `Array1D#[]` already uses for its own nested chunks.
  `#[]=`/`#to_lcf` needed no changes -- they already handled a mixed
  String/`Array1D` entry, so an untouched row now round-trips as a direct
  byte passthrough rather than a decode-then-reencode. Verified locally for
  round-trip fidelity (passthrough, decode-and-cache identity, sparse-table
  holes, an empty writable-from-scratch table, editing one row without
  disturbing siblings, and a nested `Array2D`-inside-`Array1D` field); the
  existing synthetic RPG2000 logic and scene checks (2000+ combined
  assertions, exercising `LCF::Database`/`LCF::MapTree`/`LCF::MapUnit`
  through real Scene::Map/battle/event-command paths) pass unchanged.
