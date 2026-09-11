- Fixed a real, live correctness bug in the opt-in (`RPGMAKER_BC2CPP=1`)
  AOT compiler: `compile_send`'s own SEND/SSEND call-site argument-count
  parsing (`/n=(\d+)/`) silently misparsed two real mrbc disassembly
  shapes instead of rejecting them -- a keyword-argument call site
  (`"n=3|nk=1"`) had its whole keyword-Hash argument silently dropped,
  and a splat call site (`"n=*"`) fell through to a silently-wrong
  zero-argument call. This was live in six already-shipped, already-
  compiled methods: `Game::Battle#enemy_basic_action`/
  `#enemy_fallback_attack`'s own `deal_attack(..., charged: charged)`
  silently dropped `charged:` (every charged enemy attack routed through
  either method used `#deal_attack`'s own `charged: nil` default
  instead); `Game::Actor#knock_out!`/`Game::Battle#inflict_state`'s own
  `Game::States.prune(ids, table, keep: permanent_states)` silently
  dropped `keep:` (a permanently-protected state could be pruned as if no
  exemption list existed); `Game::Actor#restore_class`'s own
  `set_level(@level, preserve_mod: false)` silently called with
  `preserve_mod: true` instead (incorrectly carrying stat modifiers
  across a class restore); and `RPG2k::Scene::DebugMenu#play_animation`'s
  own call into three real mandatory keyword arguments used to silently
  compile a call that would raise `ArgumentError` at runtime. Unlike a
  prior round's `IvarLayout.join` embedding bug (caught by a runtime type
  guard before it could do worse than raise `TypeError`), this one had no
  safety net -- the generated C++ compiled and linked clean either way,
  so only the wrong gameplay behavior itself would ever have surfaced it.
  `compile_send` now refuses to compile any splat or keyword-argument
  call site (the same `#error`-marker fallback every other unsupported
  shape here already gets); all six affected methods correctly fall back
  to the interpreter. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
