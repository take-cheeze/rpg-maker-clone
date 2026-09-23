# 0209. bc2cpp routes dynamic calls through one out-of-line bc2cpp_send

Date: 2026-09-23

## Status

Accepted

## Context

bc2cpp-generated code is about 4x the size of the bytecode it replaces at
`-Os`, which is what the wio build uses, and about 10x at the desktop `-O3`.
`mruby-rpg2k-compiled` alone is 4.9 MB at `-Os` and 11.9 MB at `-O3`, against
about 1.1 MB for the gem's bytecode. Most of that is intrinsic: each bytecode
operation becomes a call plus argument setup. Splitting the
`bc2cpp_sym`/owner-class/constant-site helpers into an inline fast path and a
cold slow path was measured first, and made the code slightly larger (+11 KB
at `-Os`), because the compiler already kept those slow paths out of line.

The one per-site cost that could still be removed is the dynamic-dispatch
fallback. SYMBOL_CACHE rewrote every `mrb_funcall(M, recv, "name", n, ...)` into
`mrb_funcall_id(M, recv, bc2cpp_sym(M, i), n, ...)`: two calls with register
moves between them at each of the 19,664 sites in the RPG2k gem.

## Decision

SYMBOL_CACHE now rewrites those calls into `bc2cpp_send(M, recv, i, n, ...)`.
It is a file-scope helper that does what `mrb_funcall_id` does, including the
same 16-argument limit and `ArgumentError`, with the `bc2cpp_sym` lookup
folded in, and ends in the same `mrb_funcall_argv`. So each site makes one
call, and the work on the fallback path is unchanged.

## Consequences

`mruby-rpg2k-compiled` shrinks by 194 KB at `-Os` (4.944 -> 4.750 MB, -3.9%)
and by 327 KB at `-O3` (12.011 -> 11.685 MB); lcf and rgss lose 2 KB and 7 KB
at `-Os`, and the desktop binary loses 492 KB. Behaviour is unchanged:
`scripts/bc2cpp_symbol_cache_check.rb` checks the rewrite and runs the emitted
helper against stubs (receiver, symbol and arguments forwarded, the limit
raised), and a real `RPGMAKER_BC2CPP=1` build passes the RGSS probes, a New
Game boot and `--rpg2k_battle_play`.

This does not change the order of magnitude. Compiling only the methods that
matter for speed (leaving cold ones such as save/load and menus as bytecode)
is the change that would.
