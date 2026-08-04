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

## Pull Requests

Every change lands on `master` through a pull request — do not push to `master`
directly. Before opening one:

- **One logical change per branch/PR.** Keep the diff focused; unrelated
  cleanups belong on their own branch so reviews and reverts stay clean.
- **Branch naming.** Work on a `claude/<short-topic>-<suffix>` branch (matching
  the existing `claude/rpg2k-todos-nftv59`, `claude/mv-move-smoke-e6qtsr` history),
  create it if it does not exist, and never push to a branch you were not asked
  to use.
- **Format before committing.** Run pre-commit after finishing edits so
  `clang-format`, `cmake-format`, `nixfmt`, trailing-whitespace and
  end-of-file-fixer all pass (`pre-commit run --all-files`, or install the hook
  with `pre-commit install`). CI and reviewers expect an already-formatted diff.
- **Add a changelog fragment.** Drop one `changelog.d/<slug>.<category>.md` file
  per change instead of editing `CHANGELOG.md` (see the Documentation
  Requirements above and `changelog.d/README.md`).
- **Record an ADR when the change is architectural.** New dependencies,
  patterns, integrations or schema changes get a `docs/adr/` entry (see below),
  and user-facing capabilities get matching `/docs` and `README.md` updates.
- **Run the tests you touched.** Build and run the Google Test / CTest suite
  (`cmake --build build -t test`) and any relevant `scripts/*_check.rb`
  validators before pushing.
- **Open a PR when there is code to review.** Push with
  `git push -u origin <branch>`, then open a pull request whenever the change
  includes code that needs review. Each PR gets a **Cloudflare Pages** preview
  and must keep CI green before it is merged; pushes to `master` deploy the page
  to **GitHub Pages**.
- **Auto-merge counts as approval — keep moving.** When a PR has auto-merge
  enabled, treat it as already review-approved: do not block waiting for the
  merge to land. Move straight on to the next task if there is work left to do;
  the PR merges itself once CI passes.
- **Resolve conflicts when you find them.** When a branch or PR has merge
  conflicts against `master` (a push to `master` made the PR un-mergeable, or a
  merge/rebase stops on a conflict), resolve them yourself rather than leaving
  them: merge the latest `master` into the branch (or rebase onto it, per the
  branch's convention), fix the conflicted files, re-run the checks you can, and
  push. Only ask when a conflict is genuinely ambiguous — both sides changed the
  same logic and picking one silently drops behavior.

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

### mruby stdlib methods live in core `*-ext` mrbgems — depend on them

mruby's base classes are deliberately minimal; many methods you expect from
CRuby live in separate **core mrbgems** (`mruby-array-ext` for `Array#-` /
`#difference` / `#compact` / …, `mruby-numeric-ext` for `Integer#zero?`,
`mruby-hash-ext`, `mruby-string-ext`, `mruby-enum-ext`, …). If your Ruby uses
such a method, **do not hand-roll a workaround** (e.g. `reject`/`==` instead of
`-`/`zero?`) — use the real method and make sure the providing core gem is
present:

- **Declare it in the gem that uses it.** Add `add_dependency '<gem>'` to that
  gem's `mrbgem.rake` (see `mruby-mvjs/mrbgem.rake` depending on
  `mruby-array-ext`). This is what makes the method available in the gem's own
  **test** build — the per-gem `rake test` binary only pulls the gem plus its
  declared dependencies, so a method that works in the full game build can still
  be "undefined method" in CI's `mruby_test` if the dependency is not declared.
  This exact gap produced `undefined method '-' for Array` for MZ.
- If the whole game needs it too, it also belongs in the shared list in
  `build_config.rb` (`rpg_maker_gems`) — but the gem-level `add_dependency` is
  the part that keeps the tests honest, so prefer to always add it there.

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
  documented field. Synthetic blobs cannot catch a mistyped field, so validate
  against genuine output.
- The save layer can also **write** `.lsd` (`mruby-lcf` `to_lcf` / `write_ber` /
  `encode` / `Array1D#[]=`, ADR 0018). Verify the writer with
  `ruby scripts/lcf_save_roundtrip.rb <path/to/Save01.lsd>`: it re-serializes a
  real save byte-for-byte and edits+reloads scalar fields through the schema.
  Because unedited chunks (including the undocumented 102/112/200) are copied
  raw, the round-trip is exact without those chunks being documented.
- Generate a real save headlessly with `./scripts/gen-lcf-save-wine.bash`: it
  boots a game's EasyRPG Player under wine (Xvfb + `matchbox-window-manager` so
  the SDL window gets input focus) with `--test-play` and uses the **debug menu**
  (F9 → Save → slot) to write a genuine `Save<N>.lsd` from anywhere — no
  playthrough needed, which is how a real **RPG2003** save is obtained despite
  those games' menu-disabled intros (and Nepheshel's Gate-only saving). It then
  runs `lcf_save_check.rb`. Defaults to the mtf-meido-action RPG2003 test-bed;
  pass a game dir + slot for others. Input notes for driving EasyRPG under Xvfb:
  a window manager is required (no WM → wine never focuses the window → keys are
  dropped), decision keys must be *held* (keydown/pause/keyup, not a tap), and
  menu-cursor moves want short taps. See ADR 0017.
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
  - **111** — `SAVE_MAP_EVENT`: field 11 is each map event's live position
    (`SAVE_MOVABLE`) — confirmed because all 21 saved entries match map 12's 21
    defined events by id and sit in-bounds (`lcf_save_check.rb` re-checks this
    when the map's `.lmu` is beside the save). Two leading int fields (1, 2, the
    map scroll/pan) stay undecoded pending differential saves.
  - **108** — `SAVE_PARTY_ACTOR`, one entry per actor the party has held. Beyond
    the state block, the decoded fields are level (31), exp (32), skills (51/52),
    equipment (61, five item ids `[weapon,shield,armour,helmet,accessory]`) and
    current HP/MP (71/72) — validated because level tracks exp across the roster,
    actor 1's HP (71) matches the SAVE_TITLE `hero_hp`, and every equipment id
    resolves to a database item of the matching type. The base-stat block is
    still undecoded (see ADR 0014).
- When decoding a chunk, prove field meanings against real bytes (change one
  known thing in-game, re-save, diff) rather than guessing; document only what
  the data (or the rpg2kpsp analysis wiki) spells out, per ADR 0002.
- The runtime can resume from a real save: `Game::State.from_lsd(db, save)`
  rebuilds a `State` from a parsed `LcfSaveData` (leader position, party roster,
  gold, items, switches, variables, and each roster actor's saved level/exp,
  current HP/MP, equipment and skills from chunk 108), and `continue_game` loads an editor
  `Save<N>.lsd` when present. Actor base stats scale with level from the database
  growth curve (chunk 31, six shorts per level, via `LCF::Array1D#int16_values`),
  so a restored level rescales the maxima — see ADR 0015. `Game::Actor` also
  models five equipment slots whose item bonuses (the "points1" set plus max
  HP/SP points) fold into the effective stats; New Game equips the initial gear
  and Continue re-equips the saved gear (chunk 108 field 61) — see ADR 0016.
  `ruby scripts/rpg2k_save_load_check.rb` round-trips a real save through it. Use
  `save[101]`, not `save.system`, in CRuby-tested code — `system` resolves to
  `Kernel#system` there.
- **RPG2000 vs RPG2003:** `LCF::MODE` is a compile-time constant (2000) that only
  supplies edition-dependent *defaults* (max level, variable range); chunk
  decoding is id-driven, so a 2003 file parses either way. To branch on a file's
  actual edition use `db.maker` / `db.rpg2003?` — RPG2003 databases carry a
  Classes section (chunk 30) that RPG2000 never writes, and that presence is the
  signal (built on the `LCF::Array1D#key?` chunk-presence primitive).
  `lcf_testbed_check.rb` reports the detected edition per game and, for 2003,
  asserts the Classes table decodes and every actor's `class_id` resolves. The
  2003-specific content lives almost entirely in the database (`RPG_RT.ldb`),
  which is validated against real 2003 games (Song-of-the-Sea, mtf-meido-action);
  the `.lsd` layout is largely shared with 2000. A real 2003 save is now
  validated too: `gen-lcf-save-wine.bash` writes one from mtf-meido-action via
  the debug menu (bypassing its menu-disabled intro), and it parses through
  `SAVE_DATA` and round-trips into the runtime cleanly — see ADR 0017 (this was
  the follow-up deferred by ADR 0013).

## Testing Standards

- Unit tests are written using Google Test and executed by CTest. Use `cmake --build build -t test` to run it
