bc2cpp: make `sanitize` injective so two operator-named methods cannot collide

`cpp_name` is `sanitize("#{owner}_#{name}")` and `compile_all` emits one `_impl`
per registry leaf, so the symbol is derived from the (owner, name) pair. The old
mapping replaced every character outside `[A-Za-z0-9_]` with a single `_`, which
is not injective: `Hash#<` and `Hash#>` both became `Hash__`, and
`Hash#==`/`Hash#<=`/`Hash#>=`/`Hash#!=` all became `Hash___`. Two leaves
colliding on one symbol emit the same C++ function twice and the translation unit
fails to compile:

  error: redefinition of 'mrb_value Hash___impl(mrb_state*, mrb_value, mrb_value)'

mruby-hash-ext's `Hash#<`, `#<=`, `#>` and `#>=` are the first owner in this
program with two operator-named methods, which is why the bug stayed hidden:
those methods only enter the registry when core mrblib is part of the closed
world, and a per-gem `ONLY_OWNERS` allowlist filters them out anyway.

Each non-identifier character (including `_`, so `A_B` cannot collide with `A<B`)
now becomes `_` plus its two-digit lowercase hex code point. Verified injective
over the 29 operator/punctuation names the closed world actually uses, and every
result is a valid C identifier.
