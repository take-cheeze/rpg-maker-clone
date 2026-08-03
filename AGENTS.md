# Project Guidelines

## Documentation Requirements

-   Update relevant documentation in /docs when modifying features
-   Keep README.md in sync with new capabilities
-   Record changelog entries as fragment files in `changelog.d/`, **not** by
    editing the `## [Unreleased]` section of `CHANGELOG.md` directly. Add one
    `changelog.d/<slug>.<category>.md` file per change so branches never
    collide on the same lines. See `changelog.d/README.md` for the format;
    `scripts/build_changelog.rb` folds the fragments into `CHANGELOG.md` at
    release time.

## Architecture Decision Records

Create ADRs in /docs/adr for:

-   Major dependency changes
-   Architectural pattern changes
-   New integration patterns
-   Database schema changes
    Follow template in /docs/adr/template.md

## Code Style & Patterns

- Codes are formatted by precommit. Please run it after code edit finishes
- Most dependencies are managed by nix flake. See flake.nix for detail

## Error Handling

- Do not silence errors. Never swallow an exception (or ignore a failing
  return value) so that a failure disappears without a trace.
- When you catch an error to keep the game running (e.g. a missing asset or
  optional data field falling back to a default), still surface it — log it to
  `$stderr` with a `[RPG2k]`/`[RGSS]` tag and the underlying `e.message`, the
  way the rest of the runtime code already does. A recovered error should be
  visible in the log, not invisible.
- Prefer catching the narrowest exception you can. Avoid bare `rescue` /
  broad `rescue StandardError` when a specific class expresses the real
  failure you are recovering from.

## LCF save data (`Save<N>.lsd`)

- The `LcfSaveData` schema lives in `mruby-lcf/mrblib/schema.rb` (`SAVE_DATA`).
  Analyse a real save with `ruby scripts/lcf_save_check.rb <path/to/Save01.lsd>`;
  it lists documented vs. undocumented top-level chunks and reads every
  documented field. Generate a real save by running an RPG Maker 2000 game under
  wine (headless via Xvfb) and saving in-game — synthetic blobs cannot catch a
  mistyped field, so validate against genuine output.
- Top-level chunk map, from a real save (Nepheshel, saved at the town Gate).
  Documented in `SAVE_DATA`: 100 title, 101 system, 103 pictures, 104–107
  hero/boat/ship/airship, 108 party actors, 110 teleport targets, 111 map
  events. Empirically identified (previously undocumented — see ADR 0009/0011):
  - **102** — screen effects (tint / flash / shake), small `Array1D`.
  - **109** — inventory: party items + gold. Gold is field `0x15`; a save with
    100G stores `21 => 100`, which is how the section was confirmed.
  - **112** — a single-byte flag.
  - **113** — the foreground (map/parallel) event-interpreter execution state:
    the running event's continuation, captured mid-command (a real save taken
    from an on-screen choice keeps that choice's option strings here).
  - **114** — common-event execution state: an `Array2D` indexed by
    common-event id (505 entries for Nepheshel), each a per-event exec state.
  - **200** — a non-standard high-id chunk written by some runtimes; not part of
    the canonical RPG2000 layout, so it is intentionally left undocumented.
- When decoding a chunk, prove field meanings against real bytes (change one
  known thing in-game, re-save, diff) rather than guessing; document only what
  the data (or the rpg2kpsp analysis wiki) spells out, per ADR 0002.
- The runtime can resume from a real save: `Game::State.from_lsd(db, save)`
  rebuilds a `State` from a parsed `LcfSaveData`, and `continue_game` loads an
  editor `Save<N>.lsd` when present. `ruby scripts/rpg2k_save_load_check.rb`
  round-trips a real save through it. Use `save[101]`, not `save.system`, in
  CRuby-tested code — `system` resolves to `Kernel#system` there.

## Testing Standards

- Unit tests are written using Google Test and executed by CTest. Use `cmake --build build -t test` to run it
