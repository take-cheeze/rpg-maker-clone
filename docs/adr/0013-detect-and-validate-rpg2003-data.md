# 13. Detect the RPG Maker edition and validate real RPG2003 data

Date: 2026-08-03

## Status

Accepted

## Context

ADR 0009-0012 validated and extended the LCF save schema against a real RPG
Maker **2000** save (Nepheshel). The schema already carries the RPG Maker
**2003** additions (the Classes/職業 database, per-actor `class_id`, battle
commands, the extra weapon/animation fields), but nothing proved those decode
against a genuine 2003 project, and the parser had no way to tell which editor
wrote a file: `LCF::MODE` is a compile-time constant (2000) that only picks the
default values for absent, edition-dependent fields (max level 50 vs 99, the
variable range, ...). Chunk decoding is id-driven, so a 2003 file parses
structurally regardless, but "does the 2003-only content actually round-trip
against real editor output?" was untested.

Generating a real 2003 `Save<N>.lsd` to extend the save-level validation is
gated: the 2003 games available for testing (Song-of-the-Sea, mtf-meido-action)
open with a menu-disabled intro, so the in-game Save cannot be reached without
playing through the scripted opening. Database and map validation, however, need
no playthrough -- the editor output is on disk from the start.

## Decision

- **`LCF::Database#rpg2003?` / `#maker`** report the editor edition from the
  file itself. RPG2003 databases carry a Classes section (chunk 30) that RPG2000
  never writes, so its presence is the signal; `#maker` returns `2003` or `2000`.
  This is per-file and data-driven, independent of the compile-time `LCF::MODE`.
- **`LCF::Array1D#key?(idx)`** underlies the detector: it reports whether a chunk
  id was physically present in the file, distinguishing an absent optional
  section from one that is present but empty (both read as a falsy value through
  `#[]`).
- **`scripts/lcf_testbed_check.rb`** now prints the detected edition per game
  and, for a 2003 database, asserts the 2003-only structures decode: the Classes
  section must be readable and every actor's `class_id` must name a real class
  (or be 0 for none). RPG2000 databases are asserted *not* to carry the Classes
  chunk. This runs against the same downloaded games the harness already checks,
  two of which (Song-of-the-Sea, mtf-meido-action) are real 2003 projects.

## Consequences

- Real RPG2003 data is now validated end to end at the database and map level:
  the testbed reads Song-of-the-Sea (25 classes) and mtf-meido-action (18
  classes) as 2003, resolves every actor's `class_id` against the Classes table,
  and both Nepheshel variants as 2000 -- all maps, events and move routes across
  the games still parse cleanly. The 2003 branch is exercised in CI because
  mtf-meido-action is part of the harness's download set.
- The runtime and tools can now branch on the actual edition of a loaded project
  instead of the single compile-time `LCF::MODE`, which is the groundwork for
  applying the correct edition-dependent defaults per file.
- Save-level 2003 validation is deferred, not skipped: the `.lsd` layout is
  largely shared between the editions and the schema already models the 2003
  fields id-driven, but proving them against a real 2003 save needs a save that
  the tested games gate behind their intro. That remains follow-up, the same
  staged approach the earlier save ADRs took. No game data is vendored (games are
  downloaded, not redistributed), so the checks run against locally obtained
  projects.
