# 60. Deferred per-maker mruby gem init

Date: 2026-08-26

## Status

Accepted

## Context

`src/main.cxx` supports five RPG Maker generations in one binary (RPG2000/
2003, XP, VX/VX Ace, MV, MZ), each implemented as its own mrbgem
(`mruby-rpg2k`, `mruby-rpgxp`, `mruby-rpgvx`, `mruby-mvjs`) on top of a shared
`mruby-rgss` runtime. Which one a run needs is decided from the game
directory's own files (`RPG_RT.ldb`, `Game.ini`, `Data/*.rvdata*`,
`js/rpg_core.js`, `js/rmmz_core.js`) — a single-maker decision, made once per
run.

Until now `main()` opened mruby with the plain `mrb_open()`, which runs
mruby's own generated `mrb_init_mrbgems()` — a flat, unconditional loop over
*every* gem `build_config.rb` configures. That defines every class and
method all four maker gems carry on every run, regardless of which single one
is actually used: a plain RPG2000 game paid for RPGXP's, RPGVX's and MV/MZ's
entire class trees too. ADR 0047's Finding 1 measured combined
rpg2k+lcf+rgss mrblib alone at ~1.2–1.4 MB of live heap on a host proxy
measurement, before rpgxp/rpgvx/mvjs are even counted — on the PSP's shared
LVGL/mruby pool that is a meaningful fraction of the budget; on desktop it is
smaller relative to the pool but still pure waste for a game that will never
touch three of the four maker gems.

mruby's own generated `mrb_init_mrbgems()` has no per-gem opt-out, and it is
one flat function per mruby build target — there is no supported way to ask
it to skip specific gems at runtime.

## Decision

`build_config.rb` gains `rpg_maker_gem_dispatch`, called once per build
variant right after the gem list. It registers a Rake file task that runs
*after* mrbgems.rake's own `gems.setup_build`/`gems.check` have resolved and
dependency-sorted the gem list (Rake loads every task file, including this
one, before invoking any of them, so this ordering is guaranteed regardless
of where the call is registered), and reads that same resolved
`conf.gems` — so it can never drift out of sync with `build_config.rb`'s own
gem list the way a hand-copied call order would.

For each of the four maker gems it walks that gem's own `add_dependency`
chain (stopping at a sibling maker gem, since `mruby-rpgvx` depends on
`mruby-rpgxp` and that relationship is handled explicitly, not folded into
"private") to find every gem *only* that maker needs — `mruby-eval` and the
`Binding`/`Method`/`mruby-proc-ext` trio it pulls in, for `mruby-rpgxp`. A
gem more than one maker's closure claims (`mruby-rgss` itself, chief among
them) stays in the always-init group, and so does everything
`build_config.rb` declares directly at the top of `rpg_maker_gems` (even
`mruby-lcf`, which today only `mruby-rpg2k` depends on — treating "explicitly
declared" as the boundary rather than trying to prove no other code path
needs it is the conservative call; narrowing that further is future work, not
done here). The result is written to a small generated C file
(`rpg_maker_gem_dispatch.c`, built and linked the same way `gem_init.c`
already is) exposing:

- `rpg_maker_init_shared_gems(mrb_state*)` — everything but the four maker
  gems, in their resolved order.
- `rpg_maker_init_rpg2k_gem`, `_rpgxp_gem`, `_rpgvx_gem` (calls `_rpgxp_gem`
  first, since RGSS2/3 extends RGSS), `_mvjs_gem` — one function per maker,
  each calling that maker's private prerequisites (if any) then the maker
  gem itself.

Each generated function reuses mruby's own per-gem
`GENERATED_TMP_mrb_<funcname>_gem_init` entry points (declared `extern "C"`),
the same ones the stock `mrb_init_mrbgems()` calls — this only changes which
function calls which of them, not what they do.

`src/main.cxx` opens mruby with `mrb_open_core()` (core classes only, no
gems) instead of `mrb_open()`, then calls `rpg_maker_init_shared_gems`
immediately, wrapped in `mrb_protect_error` (public API, `mruby/error.h`) the
same way mruby's own gem loop guards each gem's init — mruby 4.0's
`mrb_core_init_protect` does the same job but is not exported for outside
callers to use safely, so `mrb_protect_error` stands in for it here.

Which maker's gem to bring up is decided by `detect_game_kind()`, a new
`GameKind` enum-returning function factored out of the game-class dispatch
that already existed in both `main()` and (on Emscripten) `rpg_start_game()`
— both now call it once and switch on the result, instead of independently
re-running the same filesystem checks. On the CLI/native path the maker is
known before `mrb_open_core()` even runs (the game directory is a command-line
flag), so `init_maker_gem()` runs right after the shared init. On Emscripten,
where a project may not exist yet when `main()` returns control to the
browser, `rpg_start_game()` calls it once the page's loader has actually
unzipped a project into `/game` — genuinely *deferred*, not just reordered.
The `--script` dev/debug flag (arbitrary Ruby, not a game directory) keeps
the old behavior of bringing up all four maker gems, since what such a script
touches isn't known up front.

## Consequences

A run now pays only for the shared gems plus the one maker it actually uses,
instead of all four maker gems every time — the win ADR 0047's Finding 1
was measuring the cost of. This applies to every target that shares
`src/main.cxx` (desktop, Android, Emscripten); `app/psp/main.cxx` and the Wio
Terminal port have their own entry points and are untouched by this ADR.

Verified end to end on a native Linux build (`scripts/native-build-without-nix.bash`):
the full CTest suite (`mruby_test` included, which runs every gem's own
`rake test` specs unaffected by this change) passes; RPG Maker MV and MZ
sample projects boot to their title screens; a real RPG2000/2003 project
(Nepheshel) reaches its map through `mruby-rpg2k`'s now-deferred `mruby-lcf`
dependency; a real RPG Maker XP project (OpenGame.exe's editor test bed)
runs its own scripts through title, move, menu, battle and save via its
deferred `mruby-eval`/`Binding`/`Method`/`mruby-proc-ext` prerequisites. VX/VX
Ace was not boot-tested in this pass (no test-bed project was available) —
its dispatch function is the simplest of the four (no private prerequisites
of its own beyond calling `mruby-rpgxp`'s function first), so the residual
risk is low, but a real VX boot check is follow-up work.

**Measured** (2026-08-26, host x86-64, same methodology as ADR 0047's Finding
1: a plain `mrb_state`, default allocator, no LVGL pool in the way, median
`/proc/self/status` VmRSS delta over 20 runs per mode, built from this
project's own `3rd/mruby` + gem sources against `build/mruby/host/lib/libmruby.a`):

| mode (`mrb_open_core()` + ...)      | median ΔVmRSS | vs. `mrb_open()` (all four makers) |
|--------------------------------------|--------------:|------------------------------------:|
| `mrb_open()` (old, unconditional)    |     3488 KB   |                                    — |
| shared gems + `mruby-rpg2k`          |     3096 KB   |               392 KB less (~11%)    |
| shared gems + `mruby-rpgxp`          |     2612 KB   |               876 KB less (~25%)    |
| shared gems + `mruby-rpgvx`          |     2748 KB   |               740 KB less (~21%)    |
| shared gems + `mruby-mvjs` (MV/MZ)   |     2320 KB   |              1168 KB less (~33%)    |

Every maker now costs meaningfully less than the old unconditional
`mrb_open()`, confirming the change delivers on ADR 0047 Finding 1's premise
(paying for classes a run will never touch). RPG2000/2003 sees the smallest
win: `mruby-rpg2k` is the smallest of the four maker gems, so skipping the
other three (which include the larger `mruby-rpgxp`/`mruby-rpgvx`/`mruby-mvjs`)
is proportionally less of its own baseline than for, say, MV/MZ. These are
host x86-64 numbers with no LVGL pool involved (see ADR 0047 Finding 1's own
caveat: a 32-bit target's `RVALUE`/`mrb_value` sizes roughly halve, so the
device-side delta is plausibly smaller in absolute terms but not by an order
of magnitude); a PSP/Wio-side measurement, and deciding whether `mruby-lcf`
and similar "explicitly declared but really only used by one maker" gems are
worth narrowing further, are both left as follow-ups.
