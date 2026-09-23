- **A bc2cpp-compiled `begin`/`rescue` no longer loses the values its
  registers held when the protected region was entered.** The region's body
  becomes a separate C++ function run under `mrb_protect_error`. Its context
  carried only `self` and the method's raw C++ parameters, which is the whole
  live-in state only when `begin` is the method's first instruction. The
  region recognizer also admits a `begin` reached by a branch:
  - **After an optional argument's default.** `RPG2k::Scene::Map#drive_battle(it
    = @interpreter)`, called with no argument, ran its body with `it` still
    nil. On the bc2cpp desktop build, the boot check's map-triggered battles
    failed with "undefined method 'battle_request' for NilClass".
  - **After an `if ...; return; end` guard.** There every local assigned
    before the guard read as nil.

  Such a region now captures the whole register file by value, the way a
  nested region already did. A region that starts right after `ENTER` keeps
  the lean `self` + arguments context. `scripts/bc2cpp_rescue_live_in_check.rb`
  pins all three shapes.
