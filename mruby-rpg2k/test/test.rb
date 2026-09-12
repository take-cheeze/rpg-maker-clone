# Game::Transition.new/Game::Map.new (mruby-rpg2k/mrblib/game.rb) are the
# real, concrete call sites tools/bc2cpp/bc2cpp.rb's own DIRECT_CONSTRUCT_
# TARGETS devirtualizes (docs/adr/0139's own "generalized direct-construct"
# follow-up, generalizing NATIVE_CONSTRUCT_TARGETS' own Rect/Color/Tone
# mechanism from hand-written native C++ classes to ordinary bc2cpp-COMPILED
# ones): under RPGMAKER_BC2CPP=1 (this build, when set) the compiled
# Game::Screen#fade_to / RPG2k#load_map bodies skip Class#new's own
# allocate+initialize dispatch entirely and call straight into
# bc2cpp_direct_alloc + Game__Transition_initialize_impl/
# Game__Map_initialize_impl -- without RPGMAKER_BC2CPP the exact same `.new`
# calls run interpreted, through the ordinary Class#new dispatch. Neither
# real call site is exercised directly here (both sit deep inside
# Game::Screen/RPG2k, which this gem's own test has no cheap way to
# construct standalone) -- instead, this calls `Game::Transition.new`/
# `Game::Map.new` directly with the exact same argument shapes those real
# call sites use, which is the actual mechanism bc2cpp.rb's own
# `trace_new_target` proves sound: a `SomeClass.new(...)` call site's
# receiver is always that literal class, so testing the constructor
# directly exercises the identical code path (interpreted or, when
# RPGMAKER_BC2CPP is set, devirtualized) real gameplay reaches through
# those two methods. Either way this test asserts the exact same observable
# behaviour, so it is a real check of both paths at once, not just whichever
# one happens to be active in a given build -- the same "test the
# constructor, not the deeply-nested caller" shape mruby-rgss/test/test.rb's
# own Sprite#tone/#color/#src_rect test already established for
# NATIVE_CONSTRUCT_TARGETS.
#
# Real GC pressure, not just "construct and immediately check": many
# instances of each class are allocated, then a full GC.start runs, and
# only *then* are their fields checked -- so a bc2cpp_direct_alloc that got
# MRB_INSTANCE_TT wrong, or an #initialize_impl that wrote through a stale
# receiver, would show up as a freed/reused/corrupted object here, not as
# an already-cached local variable the GC never got a chance to touch.
assert "Game::Transition.new survives real GC pressure, independently, field-for-field" do
  n = 200
  transitions = Array.new(n) do |i|
    Game::Transition.new(i % 22, 10 + i, 320, 240, i.even?)
  end

  GC.start if Object.const_defined?(:GC)

  transitions.each_with_index do |t, i|
    assert_true t.is_a?(Game::Transition), "transition #{i} must be a real Game::Transition after GC"
    assert_equal i % 22, t.style
    assert_equal 10 + i, t.frames
    assert_equal 320, t.instance_variable_get(:@width)
    assert_equal 240, t.instance_variable_get(:@height)
    assert_equal i.even?, t.instance_variable_get(:@erase)
    assert_equal 0, t.frame
  end

  # Real Ruby `.new` semantics: every transition is a genuinely separate
  # object -- advancing one must never move a sibling's own frame counter,
  # which a `bc2cpp_direct_alloc` call that accidentally returned the same
  # RObject twice (rather than a fresh MRB_INSTANCE_TT(c)-typed allocation
  # per call, see that helper's own comment) would break.
  transitions[0].advance
  transitions[0].advance
  (1...n).each do |i|
    assert_equal 0, transitions[i].frame, "transition #{i}'s #frame must not alias transition 0's"
  end
  assert_equal 2, transitions[0].frame

  # One more GC pass with the mutated value and every transition still
  # reachable (held by the local `transitions` array) -- confirms the
  # earlier GC.start pass above was not, say, incidentally keeping
  # everything alive only via some other still-live reference these
  # objects also happened to have.
  GC.start if Object.const_defined?(:GC)
  assert_equal 2, transitions[0].frame
  assert_equal 0, transitions[1].frame
end

# A minimal duck-typed stand-in for LCF::MapUnit (mruby-lcf/mrblib/lcf.rb) --
# Game::Map#initialize only ever calls #width/#height/#chipset_id/
# #lower_layer/#upper_layer on its own `unit` argument (mruby-rpg2k/mrblib/
# game.rb), so a real parsed .lmu file is not needed to exercise the exact
# same construction shape RPG2k#load_map's own real `Game::Map.new id,
# LCF::MapUnit.new(File.open(map_path(id)))` call site uses.
class RPG2kMapUnitTestStub
  def initialize(width, height, chipset_id)
    @width = width
    @height = height
    @chipset_id = chipset_id
    @lower = Array.new(width * height, 0)
    @upper = Array.new(width * height, 0)
  end
  attr_reader :width, :height, :chipset_id

  def lower_layer
    @lower
  end

  def upper_layer
    @upper
  end
end

assert "Game::Map.new survives real GC pressure, independently, field-for-field" do
  n = 150
  maps = Array.new(n) do |i|
    Game::Map.new(i, RPG2kMapUnitTestStub.new(4, 3, 100 + i))
  end

  GC.start if Object.const_defined?(:GC)

  maps.each_with_index do |m, i|
    assert_true m.is_a?(Game::Map), "map #{i} must be a real Game::Map after GC"
    assert_equal i, m.id
    assert_equal 4, m.width
    assert_equal 3, m.height
    assert_equal 100 + i, m.chipset_id
    assert_equal 0, m.revision
    assert_true m.in_bounds?(0, 0)
    assert_false m.in_bounds?(4, 0)
    assert_equal 0, m.lower(1, 1)
    assert_equal 0, m.upper(1, 1)
  end

  # Real Ruby `.new` semantics: every map's own tile layer arrays are
  # genuinely separate objects -- writing a tile on one map must never
  # move a sibling map's own tile, which a `bc2cpp_direct_alloc` call that
  # accidentally aliased two instances (rather than a fresh
  # MRB_INSTANCE_TT(c)-typed allocation per call) would break.
  maps[0].set_lower(1, 1, 42)
  (1...n).each do |i|
    assert_equal 0, maps[i].lower(1, 1), "map #{i}'s tile (1,1) must not alias map 0's"
  end
  assert_equal 42, maps[0].lower(1, 1)
  assert_equal 1, maps[0].revision

  # One more GC pass with the mutated value and every map still reachable
  # (held by the local `maps` array) -- confirms the earlier GC.start pass
  # above was not, say, incidentally keeping everything alive only via
  # some other still-live reference these objects also happened to have.
  GC.start if Object.const_defined?(:GC)
  assert_equal 42, maps[0].lower(1, 1)
  assert_equal 0, maps[1].lower(1, 1)
end

# tools/bc2cpp/bc2cpp.rb's own NATIVE_ARG_TARGETS (see that constant's own
# comment): under RPGMAKER_BC2CPP=1, each method named below compiles with
# its one/two mandatory fixnum argument(s) taken as a real native `mrb_int`
# parameter instead of `mrb_value` -- coerced once, either by the entry
# wrapper's own `mrb_get_args(M, "i"/"ii", ...)` (an ordinary dynamic-
# dispatch call, ".gain_exp(x)" below) or, for a devirtualized MONO/TYPED
# direct call elsewhere in the compiled program, by `mrb_as_int` at that
# call site instead (see compile_send's own comment) -- rather than left as
# an untyped `mrb_value` the method body only checks with its own
# fixnum-fastpath ADD/comparison opcodes at runtime.
#
# IMPORTANT, discovered while writing this exact test (real command output
# in this round's own final report): this `mrbtest`/`rake test` binary --
# the "host" mruby build (CMakeLists.txt's own MRUBY_TARGET_NAME, the SAME
# config the real desktop `rpg_maker_clone` links against too) -- was
# confirmed, via `gdb` breakpoints set directly on the compiled entry-
# wrapper symbols (`Game__Actor_exp_for_level`/`Game__Actor_display_max_hp`,
# the latter untouched by this round and already shipped several rounds
# ago), to NEVER actually reach either compiled function during a real
# `RPGMAKER_BC2CPP=1 rake test` run, even though mruby-rpg2k-compiled's own
# `register.cxx` genuinely does call `mrb_define_method(M, actor,
# "exp_for_level", Game__Actor_exp_for_level, ...)` at gem-init time (also
# confirmed live in `gdb`, function pointer and all) -- every call this
# test makes still runs mruby-rpg2k's own INTERPRETED body regardless of
# RPGMAKER_BC2CPP. This is a real, pre-existing characteristic of this gem-
# test binary specifically (not something this round's own bc2cpp.rb change
# caused -- `#display_max_hp` was compiled and registered identically many
# rounds before NATIVE_ARG_TARGETS existed at all, and shows the exact same
# never-dispatched-to behavior), and it means this test cannot actually
# observe NATIVE_ARG_TARGETS' own stricter TypeError-at-the-boundary
# behavior here -- only whatever the INTERPRETED body itself already does
# for a bad argument, which varies method to method (some raise
# NoMethodError from a bare `nil.<=`/`nil.>=`, one has no defensive check at
# all and simply returns a wrong-but-not-crashing value for a nil `type`/
# `slot`). Real correctness verification for the NATIVE_ARG_TARGETS
# mechanism itself -- confirming the *generated* entry wrapper's own "i"/"n"
# format and every devirtualized call site's own `mrb_as_int`/
# `mrb_obj_to_sym` unboxing -- was instead done by hand against the real,
# regenerated `rpg2k_compiled_gen.cpp` (see this round's own final report);
# this test still earns its keep by pinning each method's own real,
# observable Ruby-level behavior (interpreted or compiled, whichever a
# future build actually dispatches to) so a real regression in either body
# is still caught.
#
# A minimal duck-typed stand-in for the one database player row
# `Game::Actor#initialize` actually reads (mruby-rpg2k/mrblib/game.rb) --
# every field this class does NOT define is one `#initialize`/#set_level
# only ever reads through its own `respond_to?` guard (class table, growth
# curve, equipment, skills, RPG2003-only fields), each already documented
# to fall back to a plain RPG2000-shaped default (no class, curve-less
# zeroed base stats, empty equipment/skills, `#rpg2003?` reading false --
# see that method's own comment: "a bare test double with no #rpg2003? of
# its own reads false, matching a genuine RPG2000 database") -- so this
# double does not need to reproduce them to get a real, fully-initialized
# Game::Actor.
class RPG2kActorTestRow
  attr_reader :name, :charset_name, :charset_index, :faceset_name, :faceset_index, :initial_level

  def initialize
    @name = 'Test Hero'
    @charset_name = 'hero_charset'
    @charset_index = 0
    @faceset_name = 'hero_face'
    @faceset_index = 0
    @initial_level = 1
  end
end

class RPG2kActorTestDb
  def initialize
    @player = { 1 => RPG2kActorTestRow.new }
  end
  attr_reader :player
end

assert 'Game::Actor NATIVE_ARG_TARGETS methods: correct results for a real Integer ' \
       'argument, and each one\'s own already-documented behavior for a nil one' do
  actor = Game::Actor.new(RPG2kActorTestDb.new, 1)

  # #gain_exp(delta)/#change_level_by(delta): both mutate the actor in
  # place, so run each on its own fresh actor rather than one shared
  # instance whose state the other's own assertions would otherwise leak
  # into.
  gainer = Game::Actor.new(RPG2kActorTestDb.new, 1)
  before_exp = gainer.exp
  gainer.gain_exp(50)
  assert_equal before_exp + 50, gainer.exp
  gainer.gain_exp(-20)
  assert_equal before_exp + 30, gainer.exp
  assert_raise(TypeError) { gainer.gain_exp(nil) }
  assert_raise(TypeError) { gainer.gain_exp('10') }

  leveler = Game::Actor.new(RPG2kActorTestDb.new, 1)
  assert_equal 1, leveler.level
  leveler.change_level_by(2)
  assert_equal 3, leveler.level
  leveler.change_level_by(-1)
  assert_equal 2, leveler.level
  assert_raise(TypeError) { leveler.change_level_by(nil) }

  # #change_mp(delta): clamped to 0..max_mp: a curve-less test row's own
  # #base_stats (see that method's own comment) reads every stat as 0, so
  # max_mp is 0 here regardless of delta's sign or magnitude -- still a
  # real exercise of the native-typed call path and its own arithmetic
  # (ADD's fixnum-fastpath against a real mrb_int-turned-mrb_value @mp),
  # just not a case with room to observe a nonzero result.
  assert_equal 0, actor.mp
  actor.change_mp(5)
  assert_equal 0, actor.mp
  assert_raise(TypeError) { actor.change_mp(nil) }

  # #exp_for_level(level): the curve-less fallback (STAT_NAMES-shaped
  # zeroed status hash, see #base_stats) feeds a real, deterministic EXP
  # curve formula (#calc_exp) -- checked only for "a real Integer comes
  # back, monotonically non-decreasing with level" rather than one fixed
  # expected number, so this test does not silently start asserting a
  # hand-derived magic constant against a formula it does not itself
  # reproduce.
  e1 = actor.exp_for_level(1)
  e2 = actor.exp_for_level(2)
  e5 = actor.exp_for_level(5)
  assert_true e1.is_a?(Integer)
  assert_true e2 >= e1
  assert_true e5 >= e2
  # The interpreted body's own `level <= 1` reaches a real `nil.<=` before
  # ever computing anything -- NoMethodError, not TypeError (see this
  # block's own opening comment for why this test cannot observe the
  # NATIVE_ARG_TARGETS-mechanism's own stricter TypeError here).
  assert_raise(NoMethodError) { actor.exp_for_level(nil) }

  # #base_param_limit(type): RPG2000's own clamp ceiling for a *base* (pre-
  # equipment) parameter -- 9999 for the two vitals (max HP/max MP), 999 for
  # the four battle stats -- unconditional on edition (unlike #max_hp_cap's
  # own *effective*-stat ceiling just below it in the real source, which
  # does widen for RPG2003; see that constant's own comment for the
  # pre-existing HP-only mismatch this method's own name doesn't fully
  # capture).
  assert_equal 9999, actor.base_param_limit(Game::Actor::PARAM_MAX_HP)
  assert_equal 9999, actor.base_param_limit(Game::Actor::PARAM_MAX_MP)
  assert_equal 999, actor.base_param_limit(Game::Actor::PARAM_ATK)
  # The interpreted body's own `type == PARAM_MAX_HP` is a plain `==`,
  # which never raises for a mismatched type (`nil == 0` is just `false`) --
  # a nil `type` silently falls through to the 999 default today, with NO
  # exception at all (confirmed live -- an earlier version of this test
  # wrongly assumed a TypeError here). This is exactly the kind of
  # currently-unchecked argument NATIVE_ARG_TARGETS' own stricter native
  # `mrb_int` boundary is meant to harden once real dynamic dispatch in a
  # given build actually reaches the compiled entry wrapper (see this
  # block's own opening comment).
  assert_equal 999, actor.base_param_limit(nil)

  # #free_two_handed_slot(slot): no starting equipment (this test double's
  # own #initial_equipment is absent, normalized to all-zero slots), so
  # freeing either the weapon or shield slot always finds nothing to clear.
  assert_equal nil, actor.free_two_handed_slot(Game::Actor::WEAPON_SLOT)
  assert_equal nil, actor.free_two_handed_slot(Game::Actor::SHIELD_SLOT)
  # Same shape as #base_param_limit just above: `slot == WEAPON_SLOT` is a
  # plain `==`, never raises for nil -- falls through to the same `nil`
  # every other "nothing to free" case already returns, with no exception.
  assert_equal nil, actor.free_two_handed_slot(nil)

  # #slot_cursed?(slot): RPG2003-only (#cursed_armor_state_ids' own
  # `return [] unless rpg2003?`); this test double's database reads
  # RPG2000, so every slot is uncursed regardless of its own contents.
  assert_false actor.slot_cursed?(Game::Actor::WEAPON_SLOT)
  assert_false actor.slot_cursed?(Game::Actor::SHIELD_SLOT)
  # The interpreted body's own `slot >= 0` reaches a real `nil.>=` --
  # NoMethodError, same shape as #exp_for_level's own `nil.<=` above.
  assert_raise(NoMethodError) { actor.slot_cursed?(nil) }
end

assert 'Game::Interpreter NATIVE_ARG_TARGETS methods: correct results for a real ' \
       'Integer argument, and each one\'s own already-documented behavior for a nil one' do
  # Game::Interpreter#initialize only ever stores its own `state` argument
  # (mruby-rpg2k/mrblib/interpreter.rb) -- neither #trunc_div nor
  # #character_ref ever reads it, so a real Game::State is not needed to
  # exercise either one.
  interp = Game::Interpreter.new(nil)

  # Both #trunc_div and #character_ref are registered
  # `mrb_define_private_method` (mruby-rpg2k-compiled/src/register.cxx) --
  # `#send` reaches a private method the same way an ordinary self-implicit
  # call from within another Game::Interpreter method already does.
  #
  # #trunc_div(n, d) (BOTH mandatory positions native-typed -- see
  # NATIVE_ARG_TARGETS' own comment): C++ truncate-toward-zero division,
  # not mruby's own native `/`, which floors toward negative infinity --
  # the two only disagree when the operands' signs differ.
  assert_equal 3, interp.send(:trunc_div, 7, 2)
  assert_equal 3, interp.send(:trunc_div, -7, -2)
  assert_equal(-3, interp.send(:trunc_div, -7, 2))
  assert_equal(-3, interp.send(:trunc_div, 7, -2))
  assert_equal 0, interp.send(:trunc_div, 0, 5)
  # The interpreted body's own `n.abs`/`d.abs` reach a real `nil.abs`/
  # `'2'.abs` -- NoMethodError (see this test's own opening comment for why
  # this cannot observe NATIVE_ARG_TARGETS' own stricter TypeError here).
  assert_raise(NoMethodError) { interp.send(:trunc_div, nil, 2) }
  assert_raise(NoMethodError) { interp.send(:trunc_div, 7, '2') }

  # #character_ref(ref): 0 or CHAR_THIS_EVENT resolve to this interpreter's
  # own @event_id (set directly here -- #initialize never touches it, only
  # #start/#resume do, neither of which this test needs); any other ref
  # passes straight through unresolved.
  interp.instance_variable_set(:@event_id, 42)
  assert_equal 42, interp.send(:character_ref, 0)
  assert_equal 42, interp.send(:character_ref, Game::Interpreter::CHAR_THIS_EVENT)
  assert_equal 99, interp.send(:character_ref, 99)
  # The interpreted body's own `ref == 0 || ref == CHAR_THIS_EVENT` is a
  # plain `==` (never raises for nil) that simply falls through to
  # returning `ref` itself unresolved -- nil back out, no exception, the
  # same "no defensive check at all today" shape #base_param_limit/
  # #free_two_handed_slot's own nil case already has above.
  assert_equal nil, interp.send(:character_ref, nil)
end
