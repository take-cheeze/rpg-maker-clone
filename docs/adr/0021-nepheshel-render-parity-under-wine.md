# 21. Verify RPG2000 rendering against a genuine RPG_RT.exe under wine

Date: 2026-08-04

## Status

Accepted

## Context

The RPG2000 renderer in `mruby-rpg2k` is a re-implementation of an engine whose
behaviour is only documented by its output. Everything shipped so far was
verified two ways:

- **Unit checks under CRuby** — `scripts/rpg2k_render_check.rb`,
  `rpg2k_logic_check.rb` and `rpg2k_scene_check.rb` load the pure-Ruby sources
  under host Ruby and pin the geometry and logic we ported.
- **Data checks** — `scripts/lcf_testbed_check.rb` parses real games.

Both have the same blind spot: they never run *the shipped binary* on a real
game and look at the resulting pixels. That let two whole classes of defect
through.

The first class is **mruby/CRuby divergence**. The host checks run under CRuby,
where the sources happen to be valid; mruby is a smaller language. Two examples
were live on `master`:

- `Game::ChipsetLayout`, `Game::EventGraphic`, `Game::MessagePalette` and
  `Game::Parallax` declared their methods with a bare `module_function`. CRuby
  treats that as "everything after this is a module function"; mruby's
  implementation of the zero-argument form is a documented no-op
  (`3rd/mruby/src/class.c`, `/* set MODFUNC SCOPE if implemented */`). So
  `Game::ChipsetLayout.anim_ab` did not exist in the shipped engine, New Game
  raised `NoMethodError`, and **Nepheshel could not be played at all** — while
  every unit check passed.
- `Enumerable#none?` lives in the optional `mruby-enum-ext` gem, which this
  build does not pull in; the one call site crashed the engine mid-cutscene.

The second class is **rendering that is plausible but not what RPG_RT does**:
a window four pixels off, menu text drawn flat white instead of through the
windowskin's colour swatch, a message window sized to its text instead of the
fixed panel, a camera pan that outlives the map it belonged to. No amount of
self-consistent unit testing finds these, because our own expectations are what
is wrong.

Both classes are found immediately by putting the two runtimes side by side.

## Decision

Add `scripts/compare-nepheshel-wine.bash`: a headless side-by-side harness that
boots the **genuine RPG_RT.exe** under wine and our engine on the same game,
drives both with the same key script, and captures/diffs every step.

Running the real Enterbrain runtime headlessly needs four things that each cost
a debugging round, so they are recorded in the script's header and here:

- RPG_RT drives **DirectDraw**, which wine implements over wined3d → OpenGL.
  Without a **32-bit libGL** wine logs `Failed to load libGL` and every frame is
  black. Mesa's software rasteriser (`LIBGL_ALWAYS_SOFTWARE=1`) is enough; no
  GPU is required. This is why the earlier
  `scripts/run-nepheshel-easyrpg-wine.bash` concluded RPG_RT "fails under Xvfb"
  and fell back to EasyRPG Player — it does not; it just needs GL.
- RPG_RT asks for a **640x480 16-bit** mode. Xvfb cannot switch modes, so the
  screen has to already be `640x480x16`.
- A **window manager** must run, or wine never focuses the window and every
  synthesised key is dropped.
- Keys must be **held** (keydown, pause, keyup); a tap falls between two polls.

Because the reference runs in a 16-bit visual, almost every pixel differs from
ours by ±1 per channel from RGB565 quantisation, so the harness's pixel metric
uses `compare -fuzz` — without it the metric reports "everything differs" and
carries no signal.

To make the LCF path reachable without a human at the keyboard, the engine also
gains `--rpg2k_new_game`, mirroring the existing `--mv_new_game`: it picks the
title's default entry once and logs `[RPG2k-MAP] map=<id> x=<x> y=<y>`. CI runs
it against the real Nepheshel data, so an exception on the New Game → map path
fails the build instead of waiting for someone to notice.

## Consequences

The comparison is now the authority for RPG2000 rendering questions, and the
discrepancies it found are fixed:

| Fixed | Was | RPG_RT (measured) |
| --- | --- | --- |
| Title command window | 72x64 at y=160 | 64x64 at (128, 148); width = widest label + 16, bottom edge at `height * 53 / 60` |
| Selection cursor | flat blue bar over the row | the windowskin's 32x32 cursor block as a 9-patch, 4px wider than the content area on each side, exactly the row's height |
| Window / message text | flat white | shadow glyph at +1,+1 from the System shadow block, then the glyph filled from the colour swatch |
| Message window | 300px wide, inset 10px, height fitted to the text, 14px rows | fixed 320x80 at x=0 (y = 0 / 80 / 160), 16px rows |
| Frame pacing | ~44fps (sleeping "the rest of 16ms" let `lv_delay_ms` overshoot accumulate) | 60fps, from a carried-forward deadline — every timed thing (walk cycles, animated tiles, message reveal, Wait) ran a quarter too slow |
| Pictures across a map change | kept | erased (RPG2003 is the edition that added a per-picture flag) |
| Pan Screen offset / lock across a map change | kept | cleared; keeping it drew a 320x240 map from (304, 352), i.e. a blank screen |
| Chipset graphic on teleport | previous map's | reloaded for the destination map |
| Screen background | LVGL's light grey, with scrollbars | black, no scrollbars |

What is left is the **font**: RPG_RT renders with Windows' 12px MS Gothic, we
(like EasyRPG) use Shinonome. The metrics match — glyph advances, line height
and every window that sizes itself to text land on the same pixels — but the
glyph shapes differ, so the title screen's residual diff is the text and
nothing else. Shipping MS Gothic is not an option, so this stays as the known
floor for the pixel metric.

The cost is that the harness cannot run in CI as it stands: it needs a wine
prefix, 32-bit GL and a copy of the game with `RPG_RT.exe`, and it takes
minutes. It is a developer tool, run when RPG2000 rendering changes. CI gets
the cheap half — `--rpg2k_new_game` against the real game — which is what
catches the mruby/CRuby class of bug.

A follow-up this deliberately leaves open: the two runtimes desynchronise
during Nepheshel's long timed opening, so only the title screen and windows can
be compared pixel-for-pixel today. Comparing an arbitrary in-game map wants
both runtimes resumed from the *same* `Save01.lsd` (which
`scripts/gen-lcf-save-wine.bash` can already produce and both runtimes can
load) rather than driven there by counting key presses.

## Addendum: the save-based comparison

That follow-up is now implemented as
`scripts/compare-nepheshel-save-wine.bash`. Loading a save is not timed, so it
cannot drift: our engine reaches the map with `--rpg2k_continue` (the title
auto-select of `--rpg2k_new_game`, pointed at entry 2), and RPG_RT with a fixed
three-key sequence — Down, Return, Return — instead of the ~130 confirmations
the opening needs. `scripts/gen-rpg2k-save.rb` moves the party in that save to
whichever map the comparison wants.

Two things had to be learned the hard way, and both are worth keeping:

**The save must be a genuine one.** `Game::State#to_lsd` can write a
`Save<N>.lsd` from nothing and it round-trips through our own parser, so it
looked usable — but RPG_RT silently refuses to load it and "Continue" just
does nothing on the title screen. A real save carries sixteen chunks and
11–18 KB; `to_lsd` emits five and ~180 bytes, with no vehicles, pictures, map
events or common events, and none of the three chunks (102, 112, 200) that are
not in our schema at all. `scripts/lcf_save_roundtrip.rb` could never have
caught this: it only proves we can re-read our own output. So the harness starts
from a save `gen-lcf-save-wine.bash` produced with EasyRPG and *edits* it, which
preserves every untouched chunk byte-for-byte.

**The first thing the comparison found: shown pictures are not restored on
load.** Resuming Nepheshel's opening, RPG_RT draws the cutscene's background
picture and we draw black — the choice window on top of it is already
pixel-identical. `Game::State` treats `@pictures` as transient on the stated
assumption that "RPG2000's HUD pictures are re-shown by parallel events on
load", which holds for a HUD but not for a save taken mid-cutscene, where the
event that showed the picture has already run. The genuine runtime saves them in
chunk 103. Fixing it needs `LCF::Schema::SAVE_PICTURE` extended first: it models
name, visibility, zoom, transparency and tone, but *not* the picture's
position, so there is nothing to restore a picture's placement from yet. Both
that and making `to_lsd`'s own output loadable are tracked in `docs/TODO.md`.
