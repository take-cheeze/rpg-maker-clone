# 23. RPG Maker XP: driving the script host's blocking main loop per frame

Date: 2026-08-04

## Status

Accepted — driver implemented. No longer gated: the host it drives is the
default boot path ([ADR 0029](0029-rgss-script-host-by-default.md)), verified by
booting both XP beds natively in CI. A real project under the *web* build is
still the open verification.

## Context

[ADR 0017](0017-rpgxp-rgss-script-host.md) added the RGSS **script host**: a
project boots by evaluating its ~90 `Data/Scripts.rxdata` sections at the top
level, the last of which ("Main") runs the game's own loop
`$scene.main while $scene != nil`. Each `Scene_*#main` then runs its own blocking
inner loop, roughly:

```ruby
loop { Graphics.update; Input.update; update; break if $scene != self }
```

The host is still opt-in (`RGSS_SCRIPT_HOST`), with the reimplemented flow
(`game.rb`/`scene.rb`) as the default. The tracked reason has been the RGSS class
library: the display classes (`Sprite`, `Window`, `Tilemap`, `Plane`, `Bitmap`)
had to render for real before the stock scripts could draw. With the recent
`mruby-rgss` work those now render (see `docs/rpgxp-rgss-api-gap.md`), which
promotes the *other* blocker named in that doc's Notes — the blocking main loop —
to the critical path.

The problem is specific to the web build. Looking at how the frame loop is
actually entered (`src/main.cxx`):

- **Desktop** blocks: the reimplemented `RPGXP#start` runs `loop { main_loop }`
  on a real thread, and `main_loop` does one frame
  (`scene.update` → `Input.update` → `Graphics.update`).
- **Web** does *not* block: `rpg_start_game` registers
  `emscripten_set_main_loop(main_loop, 0, 0)` with `simulate_infinite_loop = 0`,
  and the C trampoline calls `mrb_funcall(M, game_obj, "main_loop", 0)` — **one
  frame per browser callback**, then returns so the browser can paint and deliver
  input. There is no Asyncify in the build.

The reimplemented flow was *designed* for this: its per-frame work is the single
`main_loop` method the callback can invoke. The script host is not — it enters
`Main`, which never returns until the game quits. Under `emscripten_set_main_loop`
that first `Scene#main` inner `loop { … }` runs forever inside one callback: the
browser never regains control, so nothing paints, no input arrives, and the tab
hangs. So the host cannot be turned on by default on the web build as written,
even now that the class library renders.

## Decision

Run the script host's blocking `Main` inside an **mruby `Fiber`**, and make the
web frame callback *resume* that fiber once per frame instead of calling
`main_loop`. `Graphics.update` (already the one call every RGSS loop makes each
frame) becomes the yield point.

- **Enter in a fiber.** When the host is enabled, `RPGXP` builds the game loop as
  `@host_fiber = Fiber.new { ScriptHost.run(@db) }` instead of pushing the
  built-in title scene.
- **Yield each frame at `Graphics.update`.** In host mode, `Graphics.update`
  performs its normal frame work (the native `gfx_update`: input poll, z-sort,
  invalidation, LVGL tick) and then `Fiber.yield`s. The script's blocking
  `loop { Graphics.update; … }` therefore advances exactly one iteration per
  resume and hands control back.
- **Resume from the existing driver.** `RPGXP#main_loop` (already what the web
  callback and the desktop `loop` call) resumes `@host_fiber` when it is set,
  falling through to the built-in per-frame work otherwise. Desktop keeps
  `loop { main_loop }`; web keeps `emscripten_set_main_loop(main_loop)`. Neither
  entry point changes — only what `main_loop` does in host mode.
- **Finish cleanly.** When `Main` returns (the game exits `$scene = nil`), the
  fiber is dead; `main_loop` clears `@host_fiber` and the game ends the same way
  the built-in flow does. `mruby-fiber` ships in the tree (via `stdlib.gembox`);
  confirm it is in the player's gembox as a build prerequisite.

This is the "per-frame `Scene#main` driver" option ADR 0017 floated, realised with
a fiber so the scripts are driven one frame per callback **without modifying the
game's scripts** and **without Asyncify**.

## Consequences

- **The host can boot on the web.** The scripts keep their blocking structure
  (unmodified, the whole point of the host) while the browser still gets control
  every frame to paint and deliver input. This is the last structural blocker to
  flipping `RGSS_SCRIPT_HOST` on by default once a game verifies end to end.
- **One yield point, matching RGSS.** Every RGSS scene loop calls
  `Graphics.update` once per frame by contract, so yielding there gives exactly
  one browser frame per game frame with no per-scene special-casing. Loops that
  legitimately spin without `Graphics.update` (a script bug) would still hang —
  same as they would on hardware.
- **Fiber cost.** A fiber is a separate mruby stack; deep script call chains use
  more memory than the flat built-in loop. Bounded and small, but worth noting for
  the embedded targets (wio/psp) — those do not use `emscripten_set_main_loop` and
  could keep the plain blocking `loop`, so the fiber path can be web-only if the
  stack cost matters there.
- **Rejected: Asyncify.** Compiling with `-sASYNCIFY` so `Graphics.update` can
  `emscripten_sleep(0)` would also unblock the loop without script changes, but it
  instruments the entire call graph (including the mruby VM), inflating code size
  and slowing every call — a heavy, global cost to solve a problem a fiber solves
  locally. Keep it in reserve only if a fiber cannot span some native call frame
  the scripts trigger.
- **Verification needs a game.** Like the render work, this can only be confirmed
  by booting a real project under the web build; this ADR fixes the design so that
  work targets a settled approach.
- **Follow-up.** `exit` (the one Kernel built-in the `Interpreter` still assumes,
  per the gap doc) terminates the game by clearing `$scene`; wiring it to end the
  fiber cleanly belongs with this change.
