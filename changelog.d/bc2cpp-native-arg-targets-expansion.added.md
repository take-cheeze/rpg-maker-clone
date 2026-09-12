- `tools/bc2cpp/bc2cpp.rb`'s `NATIVE_ARG_TARGETS` (the native `mrb_int`/
  `mrb_sym` calling-convention mechanism for annotated compiled methods)
  grows from 9 to 35 entries, covering 26 more methods across
  `Game::Actor`, `Game::Map`, `Game::Transition`, `Game::Screen`,
  `Game::State`, `Game::Interpreter`, `LCF::EventCommand`, and
  `LCF::MoveCommand`. Each new entry was individually traced through the
  real regenerated output for the same two-part soundness bar the original
  round established: no defensive `nil?` guard on the annotated position,
  and every real caller's own argument provably an Integer/Symbol (a
  literal, an already-verified-safe expression, or a schema field with a
  real `default:` — never merely assumed from the annotation alone).
  23 further candidates were investigated and excluded, each for a
  specific, documented reason: a `nil`-tolerant guard already present in
  the body (the same shape as the original round's `knows_skill?`/
  `learn_skill` exclusions), non-mandatory arity from a keyword/optional
  argument, structural incompatibility with `DIRECT_CONSTRUCT_TARGETS`
  (`Game::Transition#initialize`/`Game::Map#initialize`, whose own `.new`
  codegen path passes raw `mrb_value` argv with no native-arg unboxing of
  its own), or a real call chain that could not be fully proven safe
  without a much deeper trace (`Game::State#initialize`'s own save-schema
  field lacking a `default:`, `Game::Interpreter#apply`'s own unguarded
  `when 0 then val` branch) — documented rather than forced through.
