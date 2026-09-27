bc2cpp: destroy an embedded struct's members before releasing it, so a
non-POD field cannot leak

The generated owner struct is allocated with `mrb_calloc` and released by
`mrb_data_type#dfree`, which was `mrb_free(mrb, p)` -- and `mrb_free` is
`mrb_basic_alloc_func(p, 0)`, a bare `free()`. That runs NO member destructor.

Nothing leaks today only because every C_TYPE entry is POD: the generated
fields are `mrb_int`, `mrb_sym`, `mrb_bool`, and the tagged
`Bc2cppFixnumOrNil` { mrb_bool present; mrb_int value; }. The moment a non-POD
field type is added -- a std::vector, a shared_ptr, any C++ wrapper -- the
struct would be freed without running that member's destructor, which is a silent
leak with no compiler warning.

The free-er now placement-destroys before `mrb_free`:

    static void LCF__Tree_ivars_free(mrb_state* mrb, void* p) {
      static_cast<LCF__Tree_ivars*>(p)->~LCF__Tree_ivars();
      mrb_free(mrb, p);
    }

`delete p` would be wrong: the memory comes from mruby's arena/page allocator
(3rd/mruby/src/gc.c, mrb_malloc on a page list), not `operator new`, so the
destructor and the deallocator would not match. Placement-destroy plus
`mrb_free` is the correct pairing.

Order is safe. `gc_sweep` calls `obj_free` -> `type->dfree` only for slots
`is_dead(gc, ...)` (3rd/mruby/src/gc.c), i.e. AFTER the mark phase has already
decided the object unreachable. A member destructor that ran on a LIVE object
would be a bug, and `is_dead` is what prevents it; on a dead one, destruction is
exactly when it should happen.

This is teardown correctness, which is independent of the separate liveness
question: a member holding an `mrb_value` is still UNROOTED, because
`MRB_TT_DATA` is `MRB_TT_CDATA` and the mark case calls `mrb_gc_mark_iv` on the
`iv` table only -- `mrb_data_type` has no `dmark` and nothing traverses `data`.
So this change makes holding a member safe to RELEASE; it does not make it safe
to KEEP. That would need a `dmark` hook added to mruby's GC.

Verified output-neutral for the current POD field set: generated C++ compiles
clean and object `.text` is 3,940,130, unchanged, on the hot-only wio closed
world with full compilation, core mrblib and BC2CPP_NO_ONLY_OWNERS=1.
