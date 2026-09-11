- Fixed a stale `MRB_SET_INSTANCE_TT` call left on `LCF::MoveCommand` in
  the opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler's `mruby-lcf-compiled`
  gem. `LCF::MoveCommand`'s own bare `attr_reader :command_id, ...,
  :parameter_a, :parameter_b, :parameter_c` is the exact same
  native-accessor/embedded-ivar collision shape the eighth severe bug's
  fix (`drop_unsafe_embeddings`/`natively_exposed?`) exists to catch, but
  that fix's own round never re-checked this already-shipped class
  sitting in the same file it touched. A dedicated adversarial full-sweep
  bug hunt across all 45 already-shipped classes found the drift: the
  regenerated `#initialize` body writes every ivar via plain `mrb_iv_set`
  (no embedding, confirmed against the real diagnostic and generated
  output), but the hand-written registration block still tagged every
  real instance `MRB_TT_DATA`. Confirmed harmless at the mruby-core level
  (no compiled code ever allocated or read the RData payload, so
  `DATA_PTR`/`DATA_TYPE` stayed `NULL` and every core path already
  guards on that) rather than a second live embedding bug -- but real
  drift between the hand-written registration and the generator's actual
  output, now corrected. The sweep otherwise found no ninth live bug: the
  `natively_exposed?` fix already covers writer-name collisions and
  `Struct.new`-generated accessors (both use the same synthetic
  irep-nil `MethodDef` shape), and two other structural gaps considered
  (a `NATIVE_SRCS`-only accessor colliding with an embedded ivar; a
  bytecode-defined `Enumerable` method misclassified as MONO) were
  checked and confirmed real-but-not-currently-live. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
