- One real array-ELEMENT annotation added, resolving 1 of the 17
  `ELEM_CANDIDATE` (poisoned-to-unknown) `RPG2k::Scene::*` ivars
  `tools/bc2cpp/bc2cpp.rb`'s own whole-program `ArrayElementLayout` sweep
  flagged: `RPG2k::Scene::Menu#build_commands`'s existing `-> Array`
  return annotation (added by a prior round for `ClassLayout`'s own
  `@commands` == Array fact) narrowed to `-> Array<Array>`
  (mruby-rpg2k/mrblib/scene/menu.rb) -- read in full, every real path
  (`keys.map { |key, term_name| [key, wait_term_for(key, term_name)] }`,
  and `#select_command`'s own `@commands[@index] = [:wait, wait_label]`
  SETIDX rewrite of the live Wait row) produces a plain 2-element
  `[key, label]` array literal, never anything else, so `@commands`'s
  element class is provably always `Array`. This is what lets
  `@commands.each_with_index { |(key, label), i| ... }` (the command-list
  draw/select loops) devirtualize its own per-row element access.

  The other 16 ivars in this round's list were investigated by reading
  the real mrblib source in full and correctly left poisoned -- none is
  an annotation gap, each is a genuine structural reason this analyzer's
  `-> Klass` / `-> Array<Klass>` mechanism cannot (and should not) speak
  for, without touching `ArrayElementLayout` itself (out of scope for
  this round):

  - `RPG2k::Scene::EquipMenu#@slots`, `RPG2k::Scene::Title#@menu_items`:
    both are `[term(:a), term(:b), ...]` literals, and `#term` (the one
    opaque piece) is a real, POLY method name -- defined once on
    `Game::State` (game.rb) and again on `Scene::Base` (scene/base.rb) --
    so `ArrayElementLayout`'s own `mono_ann` whole-program gate refuses
    to trust ANY annotation placed on it; annotating it would be a
    harmless no-op, never applied at any real call site.
  - `RPG2k#@scenes`: genuinely, provably polymorphic -- `#push`/`#pop`
    hold whatever scene a caller pushes (`Scene::Menu`, `ItemMenu`,
    `DebugMenu`, ...), and `#return_to_title`/`#show_game_over`/
    `#start_new_game`/`#continue_game` each wholesale-replace it with a
    *different* concrete `Scene::*` class (`Title`, `GameOver`, `Map`).
    No fixed element class exists to claim.
  - `RPG2k::Scene::Map#@last_frame`, `@flash_rgb`, `@locked_cam`: each
    is genuinely a fixed-shape tuple/cache (`[direction, pattern, bush,
    bitmap.object_id, charset_index]`, `[r, g, b]`, `[hero_cx, hero_cy]`)
    that WOULD be a uniform-Integer array at its one real populating
    site, but every one of these ivars is also repeatedly reset to a
    bare `@ivar = nil` elsewhere (a cache invalidation, not a
    construction site) -- and `ArrayElementLayout`'s own per-site join
    has no "vacuous" carve-out for a literal-nil SETIV the way it does
    for an empty-array literal (`VACUOUS`, see `array_element_source_scan`'s
    own `ARRAY`/`ARRAY2` comment); a bare `nil` write reads as `UNKNOWN`
    and poisons the join permanently. Not an annotation gap -- the
    invariant these three ivars actually have ("real Array XOR nil") is
    not one this mechanism (or a hand-placed annotation) can express at
    all without changing `ArrayElementLayout` itself.
  - `RPG2k::Scene::Map#@timer_sprites`: `[nil, nil]` at `#initialize`,
    positionally overwritten later (`@timer_sprites[id] = ...`) --
    genuinely holds `nil` AND a real sprite at once (two live timer
    slots, independently populated), not a single fixed class.
  - `RPG2k::Scene::Map#@closing_windows`: pushes `@message[:window]`/
    `@message[:gold_window]`, both real `RPG2k::Window` instances from
    the SAME `Window.new` call shape -- the invariant genuinely holds,
    but the opaque link is a `Struct#[]` read on `MessageState` (a bare
    `Struct.new(...)`, no `def` of its own anywhere), which has no
    source line to hand-place a magic comment on and is invisible to
    `build_registry` in the first place (no real `def`, so it can never
    become a `known_owners` entry `class_scoped_return_class` could ever
    resolve through).
  - `RPG2k::Scene::Map#@events`, `@parallels`: elements are, respectively,
    a `MapEventState` (`Struct.new(...)`, no `def`) and a plain `{}` Hash
    literal (`#new_parallel`) -- same structural gap as `@closing_windows`
    above (`MapEventState`) plus a second one (`@parallels`): `Hash` is
    never reopened anywhere in this closed world (confirmed by grep), so
    it is not a `known_owners` entry either and could never pass
    `ElementAnnotations`' own known-owner gate even with a hand-placed
    `-> Hash` comment.
  - `RPG2k::Scene::Map#@stuck_move_targets`, `@parallax_drawn`,
    `@event_draw_sigs`: hold plain `Integer`s (`r[:target]`, an event id),
    a genuinely heterogeneous 3-tuple (`[ox, oy, @parallax_img]` -- two
    Integers plus a Bitmap-typed image, not one class), and a positional
    signature buffer mixing `String`/`Integer`/`bool` fields
    (`store_event_draw_sig`) respectively -- none has (or could have) a
    single fixed element class; `Integer`/`Fixnum` in particular is never
    a `known_owners` entry either (no core-numeric reopen anywhere), the
    same structural gap as `Hash` above.
  - `RPG2k::Scene::Order#@names`: `@state.party.actors.map { |a|
    a.name.to_s }` -- every element genuinely is a `String`, but the one
    opaque step is the native `String#to_s`/`Kernel#to_s` call itself
    (no bytecode body, so no `def` to annotate at all), reached from an
    inline block rather than through any real helper method.
  - `RPG2k::Scene::Order#@picked`: `Array.new(@names.size)` (an array of
    `n` `nil`s, not an empty literal so not `VACUOUS`) later mixed with
    real `Integer` indices (`@picked[@counter] = @cursor_index`) and
    explicit `nil` clears (`@picked[@counter] = nil`) -- genuinely
    heterogeneous (`nil` sentinel slot vs. picked `Integer`), not a
    disagreement to paper over.
  - `RPG2k::Scene::SaveLoad#@slots`: `(1..SLOT_COUNT).map { |slot|
    parent.load_save_state(slot) }` -- `#load_save_state` is real MONO,
    but reading it in full shows it genuinely, deliberately returns `nil`
    for an empty/unreadable slot (its own `if/elsif` has no `else`, plus
    an explicit `rescue ... nil`) alongside a real `Game::State` for a
    populated one -- exactly the "a path can return nil" case this
    round's own correctness rule says never to annotate over.

  Verified with a real, isolated whole-program diff (`git stash`
  before/after the raw `== known-array-element-class hints ==`/`==
  array-element candidates ==` diagnostic, not just the aggregate
  counts): `RPG2k::Scene::Menu#@commands` is the only line that moved,
  from `ELEM_CANDIDATE` to `ELEM_HINT (Array<Array>)`, zero regressions.
  `docs/bc2cpp_coverage.txt` regenerated for real and matches
  (`scripts/bc2cpp_coverage_check.bash`): known-array-element-class hints
  (ELEM_HINT) 8 -> 9, poisoned array-element candidates 43 -> 42,
  magic-comment element annotations (ELEM_ANNOTATED) 2 -> 3, and --
  a real side effect of the new devirtualization this unlocks inside
  `@commands`' own `each_with_index` consumers -- compiled entry points
  1985 -> 1986 (one more method now compiles clean instead of falling to
  the interpreter). `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass, and a real `g++
  -fsyntax-only` pass over the regenerated whole-program output shows
  the same 6 pre-existing, unrelated `anim_target`/`command_item` errors
  and zero new ones.
