# 0472. bc2cpp: block iterators call the compiled body directly, and RGSS::Font is read without a call

Date: 2026-10-16

## Status

Accepted

## Context

On master's wio shipped pass the generated code still holds 374 `mrb_funcall_with_block` sites: sends with a block
that are not lowered to a direct call or an inlined loop. Sorted by why each one stays (counted on that pass's
`shipped.cxx`, by the enclosing function and the line before the call):

| sites | what the site is | why it keeps the dynamic send |
|------:|------------------|-------------------------------|
| 224 | engine method, literal block, the `else` of exact-class arms (`each` 94, `each_with_index` 35, `map` 34, `select` 14, `any?` 10, `each_index` 10, `times` 9, ...) | the receiver is not proven, so the Array/Hash/Range/Integer arms of ADR 0270 (and the guarded loops of ADR 0420) test it at run time and every other receiver (a user class, a subclass, nil, a bignum) dispatches. Removing the `else` needs a receiver proof, which is the receiver-class work, not this ADR. |
| 71 | compiled core body, literal block, the `else` of arms (`each` 64 on `self` in `Enumerable#all?`/`any?`/...) | `self` of an Enumerable body is any includer: by design. |
| 18 | `else` of arms inside a block that stayed a proc | same as the first row. |
| 24 | engine method, literal block, no arm at all (`loop` 7, `open` 6, `reduce` 4, `new` 3, `index` 3, `each_char` 1) | `loop` is an implicit-self send, and the arms only knew Array/Hash/Range/Integer receivers; `each_char` is a String method; `IO.open` is interpreted (it has an `EXCEPT` op); `Enumerable#inject` is interpreted (it builds a lambda); `Array#index` is a native; the `new` sites are `Array.new(n) { }` nested in a block that stayed a proc. |
| 4 | core body, literal block, no arm | `_rgss_native_sort` (a native), `IO.open`, `Struct.new`. |
| 31 | `&blk` forwarded (EXPLICIT_BLOCK_ARG) | the block is any value; calling a compiled body directly would leave an interpreted proc's `break` without the frame it unwinds to. |
| 2 | `each_line`/`Array.new` in a block that stayed a proc, no arm | `each_line` had no String arm; `Array.new` inlining (ADR 0391) runs at method level only. |

Six of the ten `times` arm sites have an Integer literal receiver (`3.times { }`, `2.times { }` nested in an inlined
`times` loop): the arm's `mrb_integer_p` test is always true there and the `else` is dead.

Of the other calls into Ruby the brief listed, the generated code holds two plain `mrb_funcall`s, both in the
`bc2cpp_str_size`/`bc2cpp_str_length` helpers under `#ifdef MRB_UTF8_STRING`, which no build of this project defines;
the rest of its by-name traffic goes through the dispatch helpers (`bc2cpp_send` and friends), not `mrb_funcall`. The
native side,
`mruby-rgss/src/lib.cxx`, reads every RGSS::Font attribute with `mrb_funcall(fv, "size", 0)` and so on for each
`draw_text`, and copies a Bitmap's font with `mrb_funcall(font, "dup", 0)`. Font is a Ruby class
(`mruby-rgss/mrblib/lib.rb`) whose attributes are `attr_accessor`s, and Font defines no `dup`.

## Decision

BLOCK_ITERATOR_DIRECT, in `tools/bc2cpp/codegen_block_core_direct.rb`, next to the arms of ADR 0270 and behind the
same switch (`BC2CPP_BLOCK_CORE_DIRECT=0` turns them off with the rest):

* **Kernel arm.** An implicit-self literal-block send whose name no class answers but mruby's own Kernel body
  (`loop { }`) calls that compiled body, `Kernel_loop_impl(M, self, blk)`. The proof is the whole world's, since the
  receiver is any `self`: no program definition of the name (the registry is empty for it), no native registration of
  it on any owner, no dynamic installer, no compiled core definition on another owner, Kernel plain (no prepend or
  unattributed mixin), the only outside Ruby source that spells a definition of the name is the file the compiled body
  comes from, defining it on Kernel alone and reopening nothing dynamically
  (`ClosedWorld#kernel_ruby_dispatch_safe?`), and no BasicObject subclass anywhere, so every `self` has Kernel.
  A yield-free block over a relaxable body (ADR 0283) leaves no `else`; otherwise the arm is
  `if (M->c == M->root_c)` with the dynamic send as its `else`, the entry guard of ADR 0269.
* **String arms.** `BLOCK_RECEIVERS` adds String (`mrb_string_p && c == string_class`, chain String, Comparable) to the
  arm receivers: `each_char`, `each_line`, `each_byte`, ... on an unproven receiver get an exact-String arm. It is a
  separate table so `RECEIVERS`, which also feeds the block-less exact-receiver and result proofs, is unchanged.
* **Integer literal receivers.** When every dominating writer of the receiver register is a `LOADI*` (through MOVEs),
  the Integer arm is the only arm and has no class test; with a yield-free block it is the whole site, no `else`.
* **`n.times { }` on an unproven receiver** (a fix to ADR 0147). The inlined loop counts in an `mrb_int` and its
  tripwire raised TypeError for any other receiver, where the interpreter runs Integer#times for a bignum, raises
  NoMethodError for a Float or nil, and calls a user class's own `times`. Now a receiver that is an Integer literal or
  that FIXNUM_OPERAND_PROOF proves keeps the plain loop; any other is a GUARDED_BLOCK_INLINE site (ADR 0420, test
  `mrb_integer_p`, which a bignum fails): the loop runs for a Fixnum at the root context, and every other receiver
  takes the site's own send, whose BLOCK_CORE_DIRECT Integer arm calls the compiled Integer#times and whose else is the
  dispatch the bytecode has. Without the guarded pass (a rescue try body, a resumable method) the site is not inlined.
* `each_line` joins the hand-vetted list of synchronous block methods (`BLOCK_FALLBACK_UPVAR_SAFE_METHODS`):
  String#each_line and the IO/StringIO `each` it aliases only `block.call` while they run. Before, a method with
  `s.each_line { |l| captured << l }` was left interpreted whole.

Every arm keeps exact semantics the way ADR 0270's do: the block is the RProc the site already built, `break`/`return`
through it use the site's catch, and every receiver an arm does not name dispatches as before. Nothing falls back by
name in a new way: each new `else` is the send the site already had.

Native side (`mruby-rgss/src/lib.cxx`): `plain_attr_read(M, obj, reader)` looks the reader up on the object's class
and, when the method is the reader mruby's `attr_reader` built for it (a cfunc proc flagged `MRB_PROC_NOARG` whose one
env slot is the reader's name with an at-sign; class.c `mod_attr_define` is the only maker of that shape), reads that
ivar with `mrb_iv_get`. Anything else (a script's override, an alias, a compiled accessor) returns undef and the caller
makes the call it made before. `read_font` and `font_default_path` use it; the Bitmap copy calls `mrb_obj_dup` directly
while Kernel#dup is what answers `dup` on the font (kernel.c registers that function), else it calls `dup`. The helper
takes the ivar from the proc, so lib.cxx spells no new ivar name (bc2cpp counts every ivar a native source spells as one
native code may write). It is plain mruby API and works the same with bc2cpp off, as on the desktop host build; no
define is involved. The pins of lib.cxx in `native_class_results.rb` and `native_ivar_scopes.rb` move to the new digest:
the change adds a read through a proc's own ivar and no write.

Check: `scripts/bc2cpp/block_iterator_direct_check.rb` (CI: `bc2cpp-build` in build.yml, after the shared generation
check). It asserts the generated arms and each world refusal (a program `def loop`, a BasicObject subclass, a dynamic
installer, a program String#each_char, the switch), then runs a fixture interpreted and compiled over the compiled core
on a full-core mruby and compares the output: each with break/next/return, each over an array grown and shrunk during
the iteration, map/select/reject/any?/all?/reduce, Integer#times (variable, literal, nested, nested break, a bignum, a negative bignum, Float/nil/String/Symbol receivers, a user class's own `times`), Hash#each and
each_key, String#each_char/each_line, Kernel#loop (break, break with a value, return, next, StopIteration, raise),
user Enumerable, Range, Hash and nil receivers, the same calls inside a Fiber (the arms' `else`), and GC stress.

## Consequences

* The dynamic `mrb_funcall_with_block` site count moves little: the Integer-literal `times` sites lose their `else`,
  and a `loop { }` whose block is yield-free loses its send. The other new arms keep their `else` for the receivers and
  the Fiber case they do not cover, so what changes for them is the run-time path: the common receiver no longer goes
  through the method cache, a call frame and the cfunc wrapper's guard.
* The 224 + 18 unproven-receiver sites need receiver proofs (claude/bc2cpp-receiver-classes). With a proven class the
  existing arm code already drops the class test, and with a yield-free block the `else`.
* Not done here, each for its own reason: `reduce`/`inject` (Enumerable#inject is interpreted because of its
  Symbol-operator lambda; a guarded inline fold would need that refusal answered first), `Array#index { }` (a native,
  so only an inline loop could replace it), `IO.open { }` (interpreted, `EXCEPT`), `Array.new(n) { }` nested in a block
  that stayed a proc, the `&blk` sites, the two `#ifdef MRB_UTF8_STRING` helper sends, and the other native calls into
  Ruby (`Input.press`/`release` from the input bridges, `RGSS.warn_stub`, and the Bitmap `blt`/`stretch_blt`/`clear`
  calls of the window skin, which go to whatever the script installed).
* The `times` loop of ADR 0147 now inlines bare only a receiver proven Fixnum, so an unproven `n.times { }` site keeps
  its send text (as the else of the guarded loop) where it had none; the send is the one the bytecode has, with its
  Integer arm in front.
