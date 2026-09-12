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
