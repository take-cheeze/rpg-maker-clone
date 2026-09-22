# 0189. Extend bc2cpp bytecode-stripping to the desktop/wasm build

Date: 2026-09-22

## Status

Accepted

## Context

`docs/adr/0144` built `wio_strip_bc2cpp_stubs` (`build_config.rb`) to delete
the interpreted-bytecode `def` of every method a `*-compiled` gem's own
`bc2cpp.rb` run registers a real C++ override for -- gated on
`spec.build.name == 'wio' && ENV['RPGMAKER_BC2CPP']`, since mruby loads a
gem's whole mrblib as one monolithic byte array, so an AOT-compiled method's
original bytecode is otherwise paid for twice (once as a bytecode blob,
once as compiled C++). That gate was wio-only because the mechanism was
first proven on the flash-constrained embedded target; later rounds widened
`owners:` for each gem (`mruby-rgss`'s list now matches its full
`compiled_gems.rb` owners exactly, `mruby-rpg2k`'s covers dozens of
`Game::*`/`RPG2k::Scene::*` classes) but never widened *which builds* the
mechanism runs for.

Nothing about the mechanism's own soundness argument is wio-specific:
`wio_registered_methods.rb` re-derives the real registered set from a fresh
`bc2cpp.rb` run every time `wio_strip_bc2cpp_stubs` is called, for whichever
build called it -- the same guarantee holds for any build.

## Decision

Widen the gate from `spec.build.name == 'wio'` to
`%w[wio host].include?(spec.build.name)`. `'host'` is the *same* unnamed
`MRuby::Build.new` `build_config.rb`'s own top-level block already defines
for both the desktop build (`cross` false) and the wasm/emscripten build
(`cross` true, `emscripten` branch) -- both real, size-sensitive final
binaries, wasm's own per-byte browser load-time cost if anything more
directly than desktop's. Deliberately not extended to `psp`/`maix`/
`android`, which never called this function at all before this change and
would need their own real-measurement verification first, per this ADR
series' own established "prove it per target" discipline.

## What was measured

A real, from-scratch `RPGMAKER_BC2CPP=1` host build (all three base gems --
`mruby-rgss`, `mruby-lcf`, `mruby-rpg2k` -- and their `-compiled`
counterparts) was built to completion both ways, changing only this one
gate, everything else (owners lists, source, toolchain) held fixed. Real
generated + compiled sizes for the three affected gems' own `gem_init.c`/
`gem_init.o` (the mrbc-embedded bytecode blob plus its compiled object
file):

| gem | `gem_init.c` before -> after | `gem_init.o` before -> after |
|---|---|---|
| mruby-rpg2k | 5,966,141 -> 1,821,629 bytes (**-69.5%**) | 7,006,008 -> 2,406,096 bytes (**-65.7%**) |
| mruby-rgss | 333,420 -> 45,076 bytes (**-86.5%**) | 1,059,184 -> 612,112 bytes (**-42.2%**) |
| mruby-lcf | 382,480 -> 287,119 bytes (**-24.9%**) | 1,007,520 -> 774,312 bytes (**-23.2%**) |

Combined `gem_init.o` reduction: 9,072,712 -> 3,792,520 bytes, a real
5,280,192-byte (~5.15 MiB) drop across just these three files, on a debug
build (`-g3`, matching this build's own `enable_debug`) -- proportionally
far larger than wio's own measured 696-byte flash recovery (docs/adr/0144),
because the desktop/wasm gate reuses the SAME already-broad per-gem
`owners:` lists (mruby-rgss's full 14-owner list, mruby-rpg2k's several
dozen `Game::*`/`RPG2k::Scene::*` classes) that wio's own history built up
over many rounds, rather than wio's original `RGSS::Sprite`-only proof.

The full `RPGMAKER_BC2CPP=1` host build (desktop target) was rebuilt to
completion end to end with this change active -- `libmruby.a` links clean,
no new compile errors introduced. Not measured: the wasm build specifically
(no emscripten toolchain in this session's sandbox) and the final linked
game executable's own size delta (this session built the mruby static
library only, not the full CMake game binary with SDL2/effekseer/etc. --
`gem_init.o`'s own size is a real, direct proxy for what a linker pulls in
from this translation unit, not a guess, but the exact number that survives
into the final stripped, non-debug release executable after `--gc-sections`
was not separately measured).

## Consequences

Every method already covered by each gem's own existing `owners:` list now
also has its original interpreted bytecode stripped from the desktop and
wasm builds, not just wio -- a real, measured multi-megabyte reduction in
generated/compiled size for the three affected gems, with the same
zero-behavior-change guarantee (`method_missing`'s ordinary `NoMethodError`
covers the same narrow, already-verified pre-override load-order window
docs/adr/0144 checked) since installation completeness is re-derived fresh
per build. `psp`/`maix`/`android` remain untouched; extending to them is a
real, separate follow-up needing its own measurement.
