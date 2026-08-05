# 29. The RGSS script host is the default boot path

Date: 2026-08-05

## Status

Accepted — supersedes the "opt-in for now" clause of
[ADR 0017](0017-rpgxp-rgss-script-host.md) (the host itself is unchanged).

## Context

An RGSS project ships its whole engine — title, map, message system, menus,
battle, plus whatever community scripts the author dropped in — as Ruby inside
`Data/Scripts.rxdata` / `Scripts.rvdata[2]`. `RGSS104E.dll` boots a game by
evaluating those sections in order; everything above the primitives is the
game's own code.

This project reached that point from two directions:

- [ADR 0010](0010-rpgxp-rgss-data-layer.md) **reimplemented** XP's default
  title/map/event flow against the database, the way `mruby-rpg2k` did for
  RPG2000. It boots a stock project to a walkable map and now handles every
  event command a real game uses ([ADR 0027](0027-rpgxp-released-game-parity.md)),
  but by construction it can only ever reproduce the *default* engine: a game
  with a custom menu, a custom battle system or any plugin script runs as though
  none of that existed.
- [ADR 0017](0017-rpgxp-rgss-script-host.md) added the **script host**, which
  runs the bundled scripts unmodified through `mruby-eval` against the native
  `mruby-rgss` class library.

The host landed switched off, and ADR 0017 named exactly what had to be true
before it could become the default. Each of those has since been closed:

- **The RGSS class library was too thin.** `Sprite`'s extended properties, the
  `Window` / `Tilemap` / `Plane` widgets, `Graphics.freeze`/`transition` and
  `Kernel#sprintf` are all in place and rendering; the remaining entries in
  [`docs/rpgxp-rgss-api-gap.md`](../rpgxp-rgss-api-gap.md) and
  [`docs/rpgvx-rgss-api-gap.md`](../rpgvx-rgss-api-gap.md) are polish, not boot
  blockers.
- **The scripts' blocking main loop could not cooperate with the web build's
  per-frame callback.** [ADR 0023](0023-rpgxp-script-host-frame-driver.md) drives
  `Main` inside a `Fiber` that the wrapped `Graphics.update` yields once per
  frame, so one browser callback is one game frame.
- **`exit` and the archive.** `Kernel#exit` raises a catchable `SystemExit` the
  driver ends the game on, and graphics and audio now load out of an encrypted
  `Game.rgssad` / `.rgss2a` / `.rgss3a`, so a packed release runs from the
  scripts too.

Meanwhile the VX / VX Ace runtime ([ADR 0024](0024-rpgvx-rgss2-rgss3-data-layer.md))
has no reimplemented flow at all: for those editions the host is the *only* way a
project runs, and an off-by-default host meant a plain boot reported "under
construction" for a game it could have played.

## Decision

Make the script host the **default** boot path for every RGSS maker, and turn
`RGSS_SCRIPT_HOST` from an opt-in into an **opt-out**.

- `RPGXP::ScriptHost.enabled?` returns true unless something says otherwise.
  Two channels, because the two runtimes read their settings differently: the
  native binary resolves `--rgss_script_host` (new, default true) and the
  `RGSS_SCRIPT_HOST` environment variable — which seeds the flag, so an explicit
  flag wins — and hands the answer to Ruby as an `RGSS_SCRIPT_HOST` **constant**,
  the way `--rpgxp_new_game` is already passed down; the CRuby harnesses have no
  such constant and set the variable, so `ENV` is consulted when it exists. This
  matters: this mruby build has no `ENV`, so before this ADR a booted game could
  not have read the variable at all. `DISABLED_VALUES` (`0`, `false`, `off`,
  `no`) is the opt-out spelling, listed on both sides.
- **The built-in flow stays, as the fallback**, on three paths that need no flag:
  a project that ships no scripts, a host that raises on the way up (the existing
  rescue in `RPGXP#drive_script_host` logs and pushes the built-in title scene),
  and an explicit `RGSS_SCRIPT_HOST=0`.
- **`--rpgxp_new_game` implies the built-in flow.** The flag drives the *built-in*
  title screen (it picks New Game without input and logs `[RPGXP-MAP]`); the
  game's own scripts show their own title and cannot be driven that way. Making
  it select the built-in flow keeps the headless render checks —
  `scripts/rpgxp_boot_check.bash`, `scripts/rgssad_asset_check.bash` and the wine
  comparison of [ADR 0025](0025-rpgxp-cross-runtime-testing.md) — measuring the
  reimplementation they were written to measure.
- **`ScriptHost.run` logs `[RPGXP-SCRIPTS] running N script sections`**, the
  script-host twin of `[RPGXP-MAP]`, so a headless run can assert that the host —
  not the fallback — booted the game.
- **CI boots each XP bed twice**: once with no flags (the host runs the game's
  own scripts; the run fails if `[RPGXP-SCRIPTS]` is missing *or* a
  `script host failed` fallback line appears, since the fallback keeps the exit
  code at zero) and once with `--rpgxp_new_game` (the built-in flow into the
  map). Both beds are covered — the editor-shaped OpenGame test bed and the
  released *Pray for You*.

## Consequences

- **A game runs as its author wrote it.** Custom menus, custom battle systems and
  community scripts — the whole reason the RGSS ecosystem exists — are on the
  default path instead of behind an environment variable, and a VX / VX Ace
  project plays instead of printing "under construction".
- **The fallback is now the exception**, which changes what a regression looks
  like: a game that used to reach the built-in map may now stop inside its own
  scripts on an `mruby-rgss` method that is still missing. The failure is
  reported and the built-in flow takes over, so a boot never ends at a blank
  window, and `RGSS_SCRIPT_HOST=0` restores the old behaviour in one step.
- **The reimplementation keeps paying for itself.** It is what the wine
  comparison diffs against the genuine runtime, the fallback for script-less
  projects, and the only path on targets too small for the host — so this ADR
  reorders the two, it does not retire either.
- **Follow-up.** The frame driver has still never been verified in a real browser
  (the browser check was removed with ADR 0025), so the web build boots the host
  on the strength of the native runs alone. The two tilemap polish items in the
  VX gap doc and the `Graphics.transition` image form remain open.
