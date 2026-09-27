bc2cpp: make the symbol mangling injective, and stop three checks reading a
truncated identifier

`cpp_name` is `sanitize("#{owner}_#{name}")` and `compile_all` emits one `_impl`
per registry leaf, so the C++ symbol is derived from the (owner, name) pair. The
old mapping collapsed every run of non-identifier characters to a single `_`,
which is not injective: `<` `>` `&` `|` `^` `+` `-` `*` `/` `%` `!` `~` all became
`_`, `<=` `>=` `==` `!=` `<<` `>>` `[]` `**` `+@` `-@` `=~` `!~` all became `__`,
and `===` `<=>` `[]=` all became `___`. mruby-hash-ext's `Hash#<` and `Hash#>`
both became `Hash__`, so two leaves emitted the same C++ function and the
translation unit failed to compile:

  error: redefinition of 'mrb_value Hash___impl(mrb_state*, mrb_value, mrb_value)'

Non-identifier characters now become `$` plus their two-digit lowercase hex code
point, except the two structural ones -- the `::` of a constant path and the `.`
of a `.singleton` pseudo-owner -- which still become a single `_`. That keeps
`Game__Actor_update`, `Widget_singleton_make` and
`bc2cpp_owner_reg_Widget_singleton` exactly as they were while making the map
injective, and `$` is a legal C++ identifier character.

Three places read a generated identifier with `\w+`, which stops at the first
`$`, so every operator- and predicate-named registration read back truncated
(`LCF__File_` instead of `LCF__File_$5b$5d`) and was reported as never
installed:

- `scripts/bc2cpp_wired_embedding_check.rb` -- its REGISTRATION_CALL
- `scripts/bc2cpp_prune_static_dispatch_registrations.rb` -- its registration scan
- `tools/bc2cpp/static_dispatch_registrations.rb` -- REGISTRATION_CALL, and IDENT,
  whose `$`-exclusion made every mangled symbol look like a runtime-built name.
  That one is why a list of provably-unreachable names
  (STATIC_DISPATCH_UNREGISTERED) suddenly looked reachable.

`mruby-lcf-compiled/src/register.cxx` spells 11 such symbols by hand (`#[]`,
`#[]=`, `#key?`, `#terminate_root?` on LCF::File, LCF::Sections, LCF::Array1D,
LCF::Array2D) and is updated to the new spelling; a stale symbol there is a link
error or an unregistered method, not a cosmetic diff.

Three checks now derive the symbols they expect from the real
`CodeGen#cpp_name` rather than writing the mangling out by hand, so they cannot
drift again: `bc2cpp_setidx_devirtualization_check`,
`bc2cpp_runtime_devirt_check`, `bc2cpp_outlined_index_check`, and
`bc2cpp_hot_only_check` (whose `EXCLUDED_SYMS` covers a `.singleton` owner).

`scripts/bc2cpp_sanitize_injective_check.rb` binds the real (private) CodeGen
method rather than copying its body, so the test cannot drift from the code.

Verified: the full hot-only wio closed world with BC2CPP_NO_ONLY_OWNERS=1 and
core mrblib compiles clean (object .text 3,605,130) with the same POLY=6403 /
TYPED=516 / MONO=3354 it had before. `bc2cpp_hot_only_check`,
`bc2cpp_nomethod_reviewed_check` (38 reviewed, 53 sites) and
`rpg2k_scene_check` (1062 checks) pass, and the full `scripts/bc2cpp_*_check.rb`
suite is back to its pre-existing 5 failures, all of which reproduce unchanged at
the commit this branch started from.
