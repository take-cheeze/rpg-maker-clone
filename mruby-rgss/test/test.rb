# The Bitmap loader consults the app-provided GAME_DIR/RTP_DIR search roots on
# every String load (the app sets them at startup in src/main.cxx). Define empty
# stand-ins so the standalone mrbtest can load fixtures by absolute/relative path
# without the search roots being defined.
GAME_DIR = "" unless Object.const_defined?(:GAME_DIR)
RTP_DIR = "" unless Object.const_defined?(:RTP_DIR)

# Regression test for the vendored mruby VM bug fixed by
# patches/mruby-dollar-bang-scoped.patch: `$!` (the exception a currently
# executing rescue clause is handling) was never implemented, so it always
# read `nil` inside a rescue clause -- silently breaking any script (a real
# VX Ace game's crash-reporter add-on, docs/rpgvx-rgss-api-gap.md item 7,
# among them) that inspects `$!` rather than the block-local variable bound
# by `rescue => e`. Scoped to the call frame containing the rescue clause,
# using mruby's existing frame-pop (cipop) as the point where it goes out of
# scope again -- so it is readable for the whole rescue body, including from
# a helper the rescue body calls, but does not leak into unrelated code that
# runs after that frame has returned.
assert "$! is set for the duration of the frame containing a rescue clause" do
  def rgss_test_dollar_bang_message
    # Read from a call the rescue body makes, not just the rescue body
    # itself, to prove $! is visible to callees within the same frame.
    $!.message
  end

  def rgss_test_dollar_bang_rescue
    raise ArgumentError, "boom"
  rescue => e
    assert_equal e, $!
    assert_equal "boom", rgss_test_dollar_bang_message
  end

  assert_nil $!
  rgss_test_dollar_bang_rescue
  assert_nil $!
end

# Companion regression test, same patch: a bare `raise` (no arguments) is
# meant to re-raise whatever `$!` currently holds -- CRuby's own documented
# behavior, used by a real VX Ace game's crash-reporter add-on to re-raise
# after logging (docs/rpgvx-rgss-api-gap.md item 7's `rescue;
# TKG::ErrorLog.save(); raise; end`). Without a working `$!`, mruby's
# `mrb_f_raise` (src/kernel.c) had nothing to fall back to, so a bare
# `raise` always raised a fresh, empty RuntimeError instead -- silently
# discarding the original exception's class and message.
assert "a bare raise re-raises the exception $! currently holds" do
  def rgss_test_bare_raise_rescue
    raise ArgumentError, "original"
  rescue
    raise # no arguments -- re-raise $!, not a fresh RuntimeError
  end

  begin
    rgss_test_bare_raise_rescue
    assert_true false # must not reach here
  rescue => e
    assert_equal ArgumentError, e.class
    assert_equal "original", e.message
  end
end

# Regression test for the vendored mruby compiler bug fixed by
# patches/mruby-colon3-assign-setmcnst.patch: `::Const = value`, written from
# inside a nested module, used to silently land on the enclosing module
# instead of at the top level. Discovered because a real VX Ace game's
# bundled add-on (docs/rpgvx-rgss-api-gap.md, item 7) relies on exactly this
# pattern to publish its own top-level API and never finished setting up.
assert "nested `::Const = value` defines the constant at the top level" do
  module RGSSTestColon3Outer
    ::RGSSTestColon3Target = self
  end
  assert_true Object.const_defined?(:RGSSTestColon3Target)
  assert_true RGSSTestColon3Target.equal?(RGSSTestColon3Outer)
  Object.send(:remove_const, :RGSSTestColon3Target)
end

# From: https://github.com/uni-algo/uni-algo?tab=readme-ov-file#normalization-functions
assert "RGSS.to_nfd" do
  assert_equal RGSS.to_nfd("Ŵ"), "W\u0302"
end

assert "RGSS.window_title records what a game names itself" do
  # No window here (mrbtest installs no hook), so this asserts the record every
  # backend keeps -- what the SDL window would have been titled with.
  RGSS.window_title = "ゆめにっき"
  assert_equal "ゆめにっき", RGSS.window_title

  # Anything else is stringised, the way a title read out of a database or an
  # ini may not be a String to begin with.
  RGSS.window_title = 2003
  assert_equal "2003", RGSS.window_title

  # A project with no title of its own clears it back to "no title" rather than
  # raising or leaving the previous game's name up.
  RGSS.window_title = nil
  assert_nil RGSS.window_title
  RGSS.window_title = ""
  assert_nil RGSS.window_title
end

assert "RGSS::Color basics" do
  c = RGSS::Color.new(10, 20, 30)
  assert_equal 10.0, c.red
  assert_equal 20.0, c.green
  assert_equal 30.0, c.blue
  assert_equal 255.0, c.alpha

  c.set(1, 2, 3, 4)
  assert_equal 1.0, c.red
  assert_equal 4.0, c.alpha

  c.red = 500
  assert_equal 255.0, c.red # clamped to 0..255
  c.blue = -10
  assert_equal 0.0, c.blue
end

assert "RGSS::Color equality and marshal" do
  a = RGSS::Color.new(1, 2, 3, 4)
  b = RGSS::Color.new(1, 2, 3, 4)
  assert_true a == b
  assert_false a == RGSS::Color.new(1, 2, 3, 5)

  loaded = Marshal.load(Marshal.dump(a))
  assert_true loaded.is_a?(RGSS::Color)
  assert_true a == loaded
end

# Regression test for two real bugs in the vendored 3rd/mruby-marshal gem
# (patches/mruby-marshal-dump-load-protocol.patch's own preamble has the
# full trail), both found via a real VX Ace game's own Game_Interpreter
# (which defines a real, standards-conforming marshal_dump/marshal_load pair
# to control what its own battle-start snapshot serializes --
# BattleManager#setup, reached the first time any event's "Battle
# Processing" command runs):
#
#   - Marshal.dump called a custom marshal_dump with one (stray nil)
#     argument instead of the zero arguments real Ruby's protocol defines,
#     raising ArgumentError on any class that defines one.
#   - Marshal.load called a custom marshal_load as a *class* factory method
#     (`klass.marshal_load data`, returning a whole new object) instead of
#     real Ruby's protocol -- allocate a new instance without running
#     #initialize, then call the *instance* method `#marshal_load(data)` on
#     it to restore state in place -- raising NoMethodError on any class
#     whose marshal_load is defined the standard way (an instance method,
#     not `self.`).
class RGSSTestMarshalDump
  def initialize(v = nil)
    @v = v
  end

  attr_reader :v

  def marshal_dump
    @v
  end

  def marshal_load(v)
    @v = v
  end
end

assert "Marshal round-trips a custom marshal_dump/marshal_load pair" do
  loaded = Marshal.load(Marshal.dump(RGSSTestMarshalDump.new(42)))
  assert_true loaded.is_a?(RGSSTestMarshalDump)
  assert_equal 42, loaded.v
end

assert "RGSS::Tone basics and clamping" do
  t = RGSS::Tone.new(-300, 20, 30, 400)
  assert_equal(-255.0, t.red) # clamped to -255..255
  assert_equal 20.0, t.green
  assert_equal 255.0, t.gray  # clamped to 0..255

  loaded = Marshal.load(Marshal.dump(t))
  assert_true loaded == t
end

# RGSS3's own stock Game_Screen#clear_tone / #clear_flash — present in every
# VX Ace project's default Scripts.rvdata2, not a community add-on — call
# `Tone.new` and `Color.new` with zero arguments: real RGSS defaults every
# component to 0 (opaque black / no tone shift) rather than requiring them.
assert "RGSS::Color.new and RGSS::Tone.new default to all-zero with no args" do
  c = RGSS::Color.new
  assert_equal 0.0, c.red
  assert_equal 0.0, c.green
  assert_equal 0.0, c.blue
  assert_equal 255.0, c.alpha # alpha's own default, same as the 3-arg form

  t = RGSS::Tone.new
  assert_equal 0.0, t.red
  assert_equal 0.0, t.green
  assert_equal 0.0, t.blue
  assert_equal 0.0, t.gray
end

assert "RGSS::Rect basics" do
  r = RGSS::Rect.new(1, 2, 3, 4)
  assert_equal 1, r.x
  assert_equal 4, r.height
  r.set(5, 6, 7, 8)
  assert_equal 5, r.x
  assert_equal 8, r.height

  assert_true r == RGSS::Rect.new(5, 6, 7, 8)

  loaded = Marshal.load(Marshal.dump(r))
  assert_true loaded == r

  r.empty
  assert_equal 0, r.x
  assert_equal 0, r.width
end

assert "RGSS::Table 1D" do
  t = RGSS::Table.new(3)
  assert_equal 3, t.xsize
  assert_equal 1, t.ysize
  assert_equal 1, t.zsize
  assert_equal 1, t.dim
  assert_equal 0, t[0]
  t[0] = 42
  t[2] = -7
  assert_equal 42, t[0]
  assert_equal(-7, t[2])
  assert_nil t[3]  # out of range
  assert_nil t[-1]
end

assert "RGSS::Table 3D and resize" do
  t = RGSS::Table.new(2, 3, 4)
  assert_equal 3, t.dim
  assert_equal 4, t.zsize
  t[1, 2, 3] = 99
  assert_equal 99, t[1, 2, 3]
  assert_equal 0, t[0, 0, 0]

  t.resize(4, 3, 4)
  assert_equal 4, t.xsize
  assert_equal 99, t[1, 2, 3] # preserved through resize
end

# A write past the edge is dropped without the value ever being looked at, which
# a game's own scripts lean on. Pray for You's `map_light` walks
# `for x in 0..(self.width)` — inclusive, so one past the end — and runs
# `@passages_data[x, y] |= 0x0f`: out there the read answers nil, `nil | 0x0f` is
# `true`, and that `true` arrives as the value of a write RGSS was always going
# to ignore. Converting arguments before the bounds check turned it into
# "TypeError: true cannot be converted to Integer" and killed the game on New
# Game.
# A game's own scripts copy these constantly — `@tone_target = tone.clone` in
# Game_Screen, `@flash_color = color.clone`, Game_Map's fog tone, Game_Picture's
# — and mruby's clone/dup allocate a bare object of the same class, copying only
# instance variables. Without initialize_copy the copy carried no native payload
# at all and the first read raised "uninitialized RGSS::Tone", which is where a
# released game stopped once it reached its map and the screen tone moved.
assert "RGSS value types survive #clone and #dup" do
  color = RGSS::Color.new(10, 20, 30, 40)
  [color.clone, color.dup].each do |copy|
    assert_equal 10.0, copy.red
    assert_equal 20.0, copy.green
    assert_equal 30.0, copy.blue
    assert_equal 40.0, copy.alpha
    # A copy is its own object: changing it must not move the original.
    copy.set(1, 2, 3, 4)
    assert_equal 1.0, copy.red
    assert_equal 10.0, color.red
  end

  tone = RGSS::Tone.new(-5, 0, 5, 50)
  [tone.clone, tone.dup].each do |copy|
    assert_equal(-5.0, copy.red)
    assert_equal 5.0, copy.blue
    assert_equal 50.0, copy.gray
  end
  # The shape Game_Screen#update runs every frame while a tone is changing.
  target = tone.clone
  moving = RGSS::Tone.new(0, 0, 0, 0)
  moving.red = (moving.red * 3 + target.red) / 4
  assert_equal(-1.25, moving.red) # components are floats, as in RGSS

  rect = RGSS::Rect.new(1, 2, 3, 4)
  copy = rect.clone
  assert_equal 1, copy.x
  assert_equal 4, copy.height
  copy.set(9, 9, 9, 9)
  assert_equal 1, rect.x, "the original rect moved with its copy"

  table = RGSS::Table.new(2, 2)
  table[1, 1] = 7
  tcopy = table.clone
  assert_equal 7, tcopy[1, 1]
  assert_equal 2, tcopy.xsize
  tcopy[1, 1] = 8
  assert_equal 7, table[1, 1], "the original table shares its copy's storage"
end

# RGSS's own RPG::Cache builds a hue variant with `@cache[path].clone` followed
# by `hue_change`, so one decode serves every hue a game asks for. That only
# works if the copy owns its pixels: hue_change rewrites the buffer in place, so
# a shallow copy would recolour the cached original along with the variant, and a
# copy with no payload at all — what mruby's clone gives a data object without
# initialize_copy — raises on first use.
assert "RGSS::Bitmap#clone copies pixels, not the handle" do
  bmp = RGSS::Bitmap.new(4, 3)
  bmp.set_pixel(0, 0, RGSS::Color.new(255, 0, 0, 255))
  bmp.set_pixel(3, 2, RGSS::Color.new(0, 255, 0, 255))

  [bmp.clone, bmp.dup].each do |copy|
    assert_equal 4, copy.width
    assert_equal 3, copy.height
    assert_equal 255, copy.get_pixel(0, 0).red.to_i
    assert_equal 255, copy.get_pixel(3, 2).green.to_i

    # Writing the copy must not reach the original — the case RPG::Cache hits
    # the moment a second hue is asked for.
    copy.set_pixel(0, 0, RGSS::Color.new(0, 0, 255, 255))
    assert_equal 255, copy.get_pixel(0, 0).blue.to_i
    assert_equal 255, bmp.get_pixel(0, 0).red.to_i,
                 "the original bitmap shares its copy's pixels"
    assert_equal 0, bmp.get_pixel(0, 0).blue.to_i

    # ...and neither must its font, which the scripts set per draw.
    copy.font.size = 9
    assert_equal 9, copy.font.size
    assert_not_equal 9, bmp.font.size
  end

  # The whole point, in the shape RPG::Cache uses it.
  variant = bmp.clone
  variant.hue_change(120)
  assert_equal 255, bmp.get_pixel(0, 0).red.to_i,
               "hue_change on a clone recoloured the cached original"
end

# Graphics.transition's transition-*graphic* form: the frozen frame gives way in
# the shape of a greyscale map — dark first, light last — with `vague` setting how
# soft the boundary is. That is what makes RMXP's default battle transition a
# pentagram rather than a fade. The shader-based players evaluate
# `clamp((t - prog) / vague, 0, 1)` on the GPU; there is none here, so it runs over
# the buffer, and this is where the arithmetic is pinned down. Whether the alpha
# it writes reaches the display is the separate job of RGSS.effect_probe.
assert "RGSS::Bitmap#_transition_alpha dissolves in the shape of a map" do
  still = RGSS::Bitmap.new(4, 1)
  still.fill_rect(0, 0, 4, 1, RGSS::Color.new(255, 0, 0, 255))
  # A left-to-right ramp: 0.0, 0.33, 0.67, 1.0 of the way through the wipe.
  map = RGSS::Bitmap.new(4, 1)
  [0, 85, 170, 255].each_with_index do |v, i|
    map.set_pixel(i, 0, RGSS::Color.new(v, v, v, 255))
  end
  vague = 40 / 255.0 # RGSS's default, on the map's own 0..255 scale

  # Alpha is how much of the still *remains*, so a pixel at 0 has given way.
  assert_true still._transition_alpha(map, 0.5, vague)
  assert_equal 0, still.get_pixel(0, 0).alpha.to_i, "the darkest pixel went first"
  assert_equal 0, still.get_pixel(1, 0).alpha.to_i
  assert_equal 255, still.get_pixel(2, 0).alpha.to_i
  assert_equal 255, still.get_pixel(3, 0).alpha.to_i,
               "the lightest pixel should go last"
  # Only the coverage changes; the still's colours are left alone.
  assert_equal 255, still.get_pixel(3, 0).red.to_i

  # `vague` is the width of the band in between, so a pixel inside it is part
  # way out rather than all or nothing...
  still._transition_alpha(map, 0.62, vague)
  edge = still.get_pixel(2, 0).alpha.to_i
  assert_true edge > 0 && edge < 255, "vague did not soften the boundary (#{edge})"

  # ...and a vague of 0 is the hard-edged wipe RGSS gives that argument: at the
  # same point in the same map, that pixel is all or nothing.
  still._transition_alpha(map, 0.62, 0.0)
  assert_equal 255, still.get_pixel(2, 0).alpha.to_i
  assert_equal 0, still.get_pixel(1, 0).alpha.to_i

  # And at the end of the wipe nothing of the still is left, whatever the map.
  still._transition_alpha(map, 1.0, vague)
  4.times do |i|
    assert_equal 0, still.get_pixel(i, 0).alpha.to_i, "pixel #{i} survived the wipe"
  end
end

# mruby's Array#sort / #sort! use -2 as the "the block did not answer with a
# number" sentinel *and* assign the block's own answer to the same variable
# (3rd/mruby/src/array.c, sort_cmp), so a comparator that legitimately answers
# -2 raised `ArgumentError: comparison failed`. Ruby only specifies the *sign* of
# a comparator, and RGSS's own scripts return a difference:
# `Scene_Battle#make_action_orders` sorts the battlers by
# `b.current_action.speed - a.current_action.speed`, which every RPG Maker XP
# game runs at the start of every battle turn — so two battlers whose speeds
# differed by exactly two ended the game. The speeds below are the ones a real
# battle produced when it did.
# Collects what a stub would have written, for the frame_reset test below.
# Defined before the assert that uses it: mrbtest runs a block as it meets it,
# so a helper declared further down the file is not there yet.
class FrameResetErr
  def initialize(lines); @lines = lines; end
  def puts(*args); args.flatten.each { |a| @lines << a.to_s }; end
  def write(s); @lines << s.to_s; end
  def print(*args); args.each { |a| @lines << a.to_s }; end
  def flush; end
end

# RGSS Graphics.frame_reset "resets the screen refresh timing": a game calls it
# after something slow so the frames that follow are not shortened to catch up.
# It used to be a warn_stub, which meant every booted game printed
# "not implemented yet" on its way to the title screen -- noise in the one log
# that is meant to be the bug list. The pacing it drives is a real absolute
# deadline (gfx_update), so this is a real method now; what a unit test can see
# is that it is native, callable and harmless.
assert "RGSS::Graphics.frame_reset is a real method, not a stub" do
  assert_true RGSS::Graphics.respond_to?(:frame_reset)
  # Answers the module, and is safe to call before any frame has been drawn --
  # a game's Scene_Title calls it before its first Graphics.update.
  assert_equal RGSS::Graphics, RGSS::Graphics.frame_reset
  assert_equal RGSS::Graphics, RGSS::Graphics.frame_reset

  # And it says nothing. A stub announces itself once through RGSS.warn_stub;
  # capturing stderr is how the harnesses check that, and here there must be
  # nothing to capture.
  said = []
  captured = $stderr
  begin
    $stderr = FrameResetErr.new(said)
    RGSS::Graphics.frame_reset
  ensure
    $stderr = captured
  end
  assert_equal [], said
end


assert "Array#sort survives a comparator that answers -2" do
  speeds = [59, 56, 66, 62, 60, 57]  # 62 and 60 are the pair that killed it
  assert_equal [66, 62, 60, 59, 57, 56], speeds.sort { |a, b| b - a }

  in_place = speeds.dup
  in_place.sort! { |a, b| b - a }
  assert_equal [66, 62, 60, 59, 57, 56], in_place

  # The sentinel itself, and its mirror, on the smallest array that reaches it.
  assert_equal [3, 1], [1, 3].sort { |a, b| b - a }
  assert_equal [1, 3], [3, 1].sort { |a, b| a - b }

  # Sorting without a block is untouched.
  assert_equal [1, 2, 3], [3, 1, 2].sort
  plain = [3, 1, 2]
  plain.sort!
  assert_equal [1, 2, 3], plain

  # And a comparator with no usable answer still fails the way it always did.
  assert_raise(ArgumentError) { [1, 2].sort { |_a, _b| nil } }
  assert_raise(ArgumentError) { [1, 2].sort! { |_a, _b| "no" } }
end

assert "RGSS::Table drops out-of-range writes without reading the value" do
  t = RGSS::Table.new(2, 2)
  t[0, 0] = 5

  assert_nil t[2, 0], "a read past the edge is nil"
  assert_nil t[0, 2]
  assert_nil t[-1, 0]

  # The exact shape from the game: nil | 0x0f == true, written back past the edge.
  value = t[2, 0] | 0x0f
  assert_true value == true, "nil | 0x0f should be true, as in RGSS"
  t[2, 0] = value
  t[0, -1] = true
  assert_equal 5, t[0, 0], "the dropped writes must not disturb the table"

  # In range, a non-Integer is still a TypeError.
  raised = false
  begin
    t[0, 0] = true
  rescue TypeError
    raised = true
  end
  assert_true raised, "an in-range write of true must still raise"
  assert_equal 5, t[0, 0]
end

assert "RGSS::Table marshal round-trip" do
  t = RGSS::Table.new(2, 2)
  t[0, 0] = 1
  t[1, 0] = 2
  t[0, 1] = 3
  t[1, 1] = 4
  loaded = Marshal.load(Marshal.dump(t))
  assert_true loaded.is_a?(RGSS::Table)
  assert_equal 2, loaded.xsize
  assert_equal 2, loaded.ysize
  assert_equal 1, loaded[0, 0]
  assert_equal 4, loaded[1, 1]
end

assert "RGSS::Bitmap pixel operations" do
  b = RGSS::Bitmap.new(4, 4)
  assert_equal 4, b.width
  assert_equal 4, b.height
  assert_equal 0, b.rect.x
  assert_equal 4, b.rect.width

  b.set_pixel(1, 1, RGSS::Color.new(10, 20, 30, 40))
  px = b.get_pixel(1, 1)
  assert_equal 10.0, px.red
  assert_equal 20.0, px.green
  assert_equal 30.0, px.blue
  assert_equal 40.0, px.alpha

  b.fill_rect(0, 0, 4, 4, RGSS::Color.new(255, 0, 0, 255))
  assert_equal 255.0, b.get_pixel(3, 3).red

  b.clear
  assert_equal 0.0, b.get_pixel(3, 3).red
  assert_equal 0.0, b.get_pixel(3, 3).alpha
end

assert "RGSS::Bitmap#disposed? reports the disposed state, not the live one" do
  # Every display class shares this pair (Viewport/Sprite/Plane/Tilemap/Window
  # too), but Bitmap is the one that needs no display, so it is where the
  # behaviour can be pinned. `disposed?` used to answer whether the object was
  # *alive*, which inverts every `unless x.disposed?` guard the stock scripts
  # use around cleanup and redraws.
  b = RGSS::Bitmap.new(2, 2)
  assert_false b.disposed?, "a fresh bitmap is not disposed"
  b.dispose
  assert_true b.disposed?, "a disposed bitmap reports disposed"
  # Disposing twice is a no-op rather than a double free.
  b.dispose
  assert_true b.disposed?
end

assert "RGSS::Bitmap blt" do
  src = RGSS::Bitmap.new(2, 2)
  src.fill_rect(0, 0, 2, 2, RGSS::Color.new(0, 128, 0, 255))
  dst = RGSS::Bitmap.new(4, 4)
  dst.blt(1, 1, src, RGSS::Rect.new(0, 0, 2, 2))
  assert_equal 128.0, dst.get_pixel(1, 1).green
  assert_equal 128.0, dst.get_pixel(2, 2).green
  assert_equal 0.0, dst.get_pixel(0, 0).alpha # untouched
end

assert "RGSS::Bitmap copy_blt matches blt onto a cleared destination" do
  # The justification for #copy_blt is that onto a *cleared* destination it
  # shows the same picture as #blt -- that is what lets the map renderer swap
  # one for the other and stay pixel-identical. Assert it over every alpha,
  # since a partial alpha is where a blend could diverge from a copy.
  #
  # "Same picture" is exact on alpha everywhere, and exact on colour wherever
  # the pixel is visible at all. The one place the two genuinely differ is the
  # colour channels of a *fully transparent* pixel: #blt skips it and leaves
  # the cleared black behind, #copy_blt copies the source's channels across.
  # Neither is observable -- blend_over weights the destination by its alpha,
  # so a da == 0 pixel contributes nothing to any later composite, and nothing
  # renders it either.
  [0, 1, 64, 128, 254, 255].each do |a|
    src = RGSS::Bitmap.new(2, 2)
    src.fill_rect(0, 0, 2, 2, RGSS::Color.new(10, 200, 30, a))

    blted = RGSS::Bitmap.new(4, 4)
    blted.clear
    blted.blt(1, 1, src, RGSS::Rect.new(0, 0, 2, 2))

    copied = RGSS::Bitmap.new(4, 4)
    copied.clear
    copied.copy_blt(1, 1, src, RGSS::Rect.new(0, 0, 2, 2))

    4.times do |y|
      4.times do |x|
        want = blted.get_pixel(x, y)
        got = copied.get_pixel(x, y)
        assert_equal want.alpha, got.alpha
        next if want.alpha == 0.0
        assert_equal want.red, got.red
        assert_equal want.green, got.green
        assert_equal want.blue, got.blue
      end
    end
  end
end

assert "RGSS::Bitmap copy_blt replaces rather than composites" do
  # Unlike #blt, it overwrites what is already there -- including replacing an
  # opaque pixel with a transparent one, which is what makes it a copy.
  src = RGSS::Bitmap.new(2, 2)
  src.fill_rect(0, 0, 2, 2, RGSS::Color.new(0, 0, 0, 0))
  dst = RGSS::Bitmap.new(2, 2)
  dst.fill_rect(0, 0, 2, 2, RGSS::Color.new(255, 0, 0, 255))
  dst.copy_blt(0, 0, src, RGSS::Rect.new(0, 0, 2, 2))
  assert_equal 0.0, dst.get_pixel(0, 0).alpha
  # ... where #blt would have left the opaque red untouched.
  other = RGSS::Bitmap.new(2, 2)
  other.fill_rect(0, 0, 2, 2, RGSS::Color.new(255, 0, 0, 255))
  other.blt(0, 0, src, RGSS::Rect.new(0, 0, 2, 2))
  assert_equal 255.0, other.get_pixel(0, 0).alpha
end

assert "RGSS::Bitmap copy_blt clips out-of-range rects" do
  src = RGSS::Bitmap.new(4, 4)
  src.fill_rect(0, 0, 4, 4, RGSS::Color.new(0, 128, 0, 255))
  dst = RGSS::Bitmap.new(4, 4)
  # Straddling both origins at once, so the source and destination clips have
  # to stay in step or the copied region lands at the wrong offset.
  dst.copy_blt(-2, -2, src, RGSS::Rect.new(-1, -1, 4, 4))
  assert_equal 128.0, dst.get_pixel(0, 0).green
  # Entirely off the destination: a no-op, not a crash.
  dst2 = RGSS::Bitmap.new(4, 4)
  dst2.copy_blt(99, 99, src, RGSS::Rect.new(0, 0, 4, 4))
  assert_equal 0.0, dst2.get_pixel(0, 0).alpha
end

assert "RGSS::Bitmap tone_blt" do
  src = RGSS::Bitmap.new(2, 2)
  src.fill_rect(0, 0, 2, 2, RGSS::Color.new(100, 150, 200, 255))

  # A neutral tone copies the source through untouched.
  dst = RGSS::Bitmap.new(2, 2)
  dst.tone_blt(src, RGSS::Tone.new(0, 0, 0, 0))
  assert_equal 100.0, dst.get_pixel(0, 0).red
  assert_equal 150.0, dst.get_pixel(0, 0).green
  assert_equal 200.0, dst.get_pixel(0, 0).blue
  assert_equal 255.0, dst.get_pixel(0, 0).alpha

  # Offsets are added per channel and clamped at both ends.
  dst.tone_blt(src, RGSS::Tone.new(50, -200, 100, 0))
  assert_equal 150.0, dst.get_pixel(1, 1).red
  assert_equal 0.0, dst.get_pixel(1, 1).green   # 150 - 200 clamps to 0
  assert_equal 255.0, dst.get_pixel(1, 1).blue  # 200 + 100 clamps to 255

  # Full gray pulls every channel to the luminance of the source pixel:
  # (100*299 + 150*587 + 200*114) / 1000 = 140.75, truncated to 140 by the
  # integer pixel path (no rounding, as elsewhere in the blitters).
  dst.tone_blt(src, RGSS::Tone.new(0, 0, 0, 255))
  assert_equal 140.0, dst.get_pixel(0, 1).red
  assert_equal 140.0, dst.get_pixel(0, 1).green
  assert_equal 140.0, dst.get_pixel(0, 1).blue

  # Toning reads the source every time rather than accumulating: repeating the
  # same call is idempotent, which is what stops a per-frame tone marching a
  # cached layer to black.
  before = dst.get_pixel(0, 1).red
  dst.tone_blt(src, RGSS::Tone.new(0, 0, 0, 255))
  assert_equal before, dst.get_pixel(0, 1).red

  # Alpha is carried through untouched -- a tone tints what shows, it does not
  # change what is visible.
  faded = RGSS::Bitmap.new(2, 2)
  faded.fill_rect(0, 0, 2, 2, RGSS::Color.new(10, 10, 10, 77))
  dst.tone_blt(faded, RGSS::Tone.new(90, 0, 0, 0))
  assert_equal 77.0, dst.get_pixel(0, 0).alpha
  assert_equal 100.0, dst.get_pixel(0, 0).red
end

assert "RGSS::Bitmap stretch_blt" do
  src = RGSS::Bitmap.new(2, 2)
  src.fill_rect(0, 0, 2, 2, RGSS::Color.new(0, 0, 255, 255))
  dst = RGSS::Bitmap.new(8, 8)
  # Stretch the 2x2 source across a 4x4 destination region.
  dst.stretch_blt(RGSS::Rect.new(2, 2, 4, 4), src, RGSS::Rect.new(0, 0, 2, 2))
  assert_equal 255.0, dst.get_pixel(2, 2).blue
  assert_equal 255.0, dst.get_pixel(5, 5).blue
  assert_equal 0.0, dst.get_pixel(0, 0).alpha # outside the destination rect
  assert_equal 0.0, dst.get_pixel(6, 6).alpha
end

assert "RGSS::Bitmap mosaic_blt" do
  # An 8-wide source, one colour per column, so each column's red channel
  # names the column it came from (col*10) and the resample is checkable
  # without guessing where a block boundary falls.
  src = RGSS::Bitmap.new(8, 1)
  8.times { |c| src.fill_rect(c, 0, 1, 1, RGSS::Color.new(c * 10, 0, 0, 255)) }

  # block_size 1 is the identity -- every pixel samples itself.
  identity = RGSS::Bitmap.new(8, 1)
  identity.mosaic_blt(src, 1)
  8.times { |c| assert_equal(c * 10.0, identity.get_pixel(c, 0).red) }

  # block_size 4 resamples each pixel from the pixel nearest the centre of
  # its 4px block (EasyRPG's own `off = block_size / 2` centring, ported
  # verbatim in mruby-rgss/src/lib.cxx's bmp_mosaic_blt) -- columns 2..5 all
  # land on the same centred block and read column 2's colour, the
  # pixelation RPG_RT's Mosaic transition applies to the whole screen.
  dst = RGSS::Bitmap.new(8, 1)
  dst.mosaic_blt(src, 4)
  [0, 1].each { |c| assert_equal 0.0, dst.get_pixel(c, 0).red }
  [2, 3, 4, 5].each { |c| assert_equal 20.0, dst.get_pixel(c, 0).red }
  [6, 7].each { |c| assert_equal 60.0, dst.get_pixel(c, 0).red }

  # Same size required, matching tone_blt/stretch_blt's own contract.
  small = RGSS::Bitmap.new(2, 2)
  assert_raise(RGSS::RGSSError) { dst.mosaic_blt(small, 2) }
end

assert "RGSS::Bitmap wave_blt" do
  src = RGSS::Bitmap.new(4, 4)
  src.fill_rect(0, 0, 4, 4, RGSS::Color.new(0, 128, 0, 255))

  # depth 0 draws every row unshifted -- a no-op wave.
  flat = RGSS::Bitmap.new(4, 4)
  flat.wave_blt(src, 0, 0.0)
  assert_equal 128.0, flat.get_pixel(0, 0).green
  assert_equal 128.0, flat.get_pixel(3, 3).green

  # A row whose offset pushes it fully off the destination leaves the
  # destination untouched there -- here still transparent, since it was
  # never filled first (the caller is expected to fill black beforehand,
  # matching how RPG_RT clears before drawing the wave -- see the Erase/Show
  # Screen Wave styles' capture draw in mruby-rpg2k/mrblib/scene/map.rb).
  # depth 10 at phase PI/2 offsets row 0 by roughly +20px, comfortably past
  # the 4px-wide destination's right edge regardless of sin's rounding.
  dst = RGSS::Bitmap.new(4, 4)
  dst.wave_blt(src, 10, Math::PI / 2)
  assert_equal 0.0, dst.get_pixel(0, 0).alpha, 'row 0 shifted fully off-screen'

  # Same size required, matching tone_blt/stretch_blt's own contract.
  small = RGSS::Bitmap.new(2, 2)
  assert_raise(RGSS::RGSSError) { flat.wave_blt(small, 1, 0.0) }
end

assert "RGSS::Bitmap gradient_fill_rect" do
  red = RGSS::Color.new(255, 0, 0, 255)
  blue = RGSS::Color.new(0, 0, 255, 255)

  # Horizontal gradient across the full width (span 9 => denominator 8).
  b = RGSS::Bitmap.new(9, 2)
  b.gradient_fill_rect(0, 0, 9, 2, red, blue)
  assert_equal 255.0, b.get_pixel(0, 0).red  # left end is color1
  assert_equal 0.0, b.get_pixel(0, 0).blue
  assert_equal 0.0, b.get_pixel(8, 1).red    # right end is color2
  assert_equal 255.0, b.get_pixel(8, 1).blue
  mid = b.get_pixel(4, 0)                     # halfway: t = 4/8 = 0.5
  assert_equal 127.0, mid.red                 # 255 - 255*0.5 = 127.5 -> 127
  assert_equal 127.0, mid.blue

  # Vertical gradient via the Rect overload + the vertical flag.
  v = RGSS::Bitmap.new(2, 9)
  v.gradient_fill_rect(RGSS::Rect.new(0, 0, 2, 9), red, blue, true)
  assert_equal 255.0, v.get_pixel(1, 0).red   # top row is color1
  assert_equal 255.0, v.get_pixel(1, 8).blue  # bottom row is color2
end

assert "RGSS::Bitmap#blur softens edges and leaves flat areas alone" do
  # A flat fill has nothing to average against itself, so a correct box blur is
  # the identity on it. This is the property that catches a blur which drags in
  # the transparent border or drifts along the scan order.
  flat = RGSS::Bitmap.new(4, 4)
  flat.fill_rect(0, 0, 4, 4, RGSS::Color.new(80, 120, 160, 255))
  flat.blur
  px = flat.get_pixel(1, 1)
  assert_equal 80.0, px.red
  assert_equal 120.0, px.green
  assert_equal 160.0, px.blue
  assert_equal 255.0, px.alpha

  # A hard vertical edge: left half white, right half black. After the blur the
  # two columns either side of the seam must move toward each other, and the
  # far columns must not (their 3x3 neighbourhood is still uniform).
  edge = RGSS::Bitmap.new(6, 3)
  edge.fill_rect(0, 0, 3, 3, RGSS::Color.new(255, 255, 255, 255))
  edge.fill_rect(3, 0, 3, 3, RGSS::Color.new(0, 0, 0, 255))
  edge.blur
  assert_equal 255.0, edge.get_pixel(0, 1).red, "far side of the edge moved"
  assert_equal 0.0, edge.get_pixel(5, 1).red, "far side of the edge moved"
  left = edge.get_pixel(2, 1).red
  right = edge.get_pixel(3, 1).red
  assert_true left < 255.0 && left > 0.0, "seam not softened: #{left}"
  assert_true right < 255.0 && right > 0.0, "seam not softened: #{right}"
  assert_true left > right, "the gradient runs the wrong way"

  # Blurring reads a snapshot, so it cannot feed its own output back in: the
  # column left of the seam sees one dark neighbour column out of three.
  assert_equal 170.0, left   # (255 + 255 + 0) / 3
  assert_equal 85.0, right   # (255 + 0 + 0) / 3
end

assert "RGSS::Bitmap#radial_blur spins around the centre" do
  # Radially symmetric input is a fixed point of a rotation about the centre, so
  # a flat fill must come back unchanged however hard it is blurred.
  flat = RGSS::Bitmap.new(9, 9)
  flat.fill_rect(0, 0, 9, 9, RGSS::Color.new(0, 0, 255, 255))
  flat.radial_blur(90, 8)
  assert_equal 255.0, flat.get_pixel(4, 4).blue
  assert_equal 255.0, flat.get_pixel(0, 4).blue

  # An asymmetric mark must smear along the arc it sweeps. A single bright pixel
  # directly above the centre of a 9x9 sits at (4, 0), radius 4; blurred over
  # +/-45 degrees it sweeps row 1 from about x=1 to x=7.
  #
  # The arc is *symmetric about the centre column*, and that is what pins the
  # centre of rotation: a flat fill is invariant under rotation about any point,
  # and a mark spreads whatever point it turns about, so neither of those alone
  # would notice the centre being wrong.
  mark = RGSS::Bitmap.new(9, 9)
  mark.fill_rect(0, 0, 9, 9, RGSS::Color.new(0, 0, 0, 255))
  mark.fill_rect(4, 0, 1, 1, RGSS::Color.new(255, 0, 0, 255))
  mark.radial_blur(90, 9)
  assert_true mark.get_pixel(4, 0).red < 255.0, "the mark did not spread"
  swept = (0...9).select { |x| mark.get_pixel(x, 1).red > 0 }
  assert_true swept.size >= 2, "no arc swept through row 1: #{swept.inspect}"
  swept.each do |x|
    mirror = 8 - x
    assert_equal mark.get_pixel(x, 1).red, mark.get_pixel(mirror, 1).red,
                 "arc is lopsided at x=#{x} vs #{mirror}: not turning about " \
                 "the centre"
  end

  # Degenerate arguments are the identity, not a divide by zero.
  same = RGSS::Bitmap.new(4, 4)
  same.fill_rect(0, 0, 4, 4, RGSS::Color.new(10, 20, 30, 255))
  same.fill_rect(0, 0, 1, 1, RGSS::Color.new(200, 0, 0, 255))
  same.radial_blur(0, 8)
  assert_equal 200.0, same.get_pixel(0, 0).red
  same.radial_blur(90, 1)
  assert_equal 200.0, same.get_pixel(0, 0).red
end

assert "RGSS::Bitmap hue_change" do
  # A 120-degree hue rotation maps the primaries exactly: R -> G -> B -> R,
  # preserving saturation, value and alpha.
  b = RGSS::Bitmap.new(2, 2)
  b.fill_rect(0, 0, 2, 2, RGSS::Color.new(255, 0, 0, 200))
  b.hue_change(120)  # red -> green
  px = b.get_pixel(0, 0)
  assert_equal 0.0, px.red
  assert_equal 255.0, px.green
  assert_equal 0.0, px.blue
  assert_equal 200.0, px.alpha  # alpha untouched

  b.hue_change(120)  # green -> blue
  assert_equal 255.0, b.get_pixel(1, 1).blue
  assert_equal 0.0, b.get_pixel(1, 1).green

  b.hue_change(0)  # no-op
  assert_equal 255.0, b.get_pixel(1, 1).blue
end

assert "RGSS::Viewport API surface" do
  # Viewport creation needs a live display, which the test binary does not set
  # up, so only assert the method surface here (exercised for real by the game).
  %i[rect rect= ox oy ox= oy= z= visible visible= update dispose disposed?].each do |m|
    assert_true RGSS::Viewport.method_defined?(m), "Viewport##{m} missing"
  end
end

assert "RGSS::Sprite API surface" do
  # opacity=/zoom_x=/zoom_y=/angle=/mirror= are native (honoured by the LVGL
  # compositor, src/lib.cxx); the rest are native too. Sprite.new needs a live
  # display, so this only asserts the method surface — the compositing itself is
  # exercised by the game runs.
  %i[bitmap= x= y= z= visible visible= opacity= zoom_x= zoom_y= angle= mirror=
     tone= color= src_rect= update blend_type= bush_depth= flash dispose
     disposed? width height].each do |m|
    assert_true RGSS::Sprite.method_defined?(m), "Sprite##{m} missing"
  end
end

# RGSS3 (VX Ace) added width/height over XP/VX's Sprite -- the graphic's own
# pixel size, mirroring its bitmap, 0 with none set. A real VX Ace release's
# own bundled speech-bubble add-on centres its tail sprite this way
# (`self.y - @tail.height / 2`), which raised NoMethodError before this.
# Pure Ruby (mrblib), needs no live display -- unlike construction, reading
# it back doesn't touch the native canvas.
assert "RGSS::Sprite#width/#height mirror the bitmap, 0 with none set" do
  sprite = RGSS::Sprite.allocate
  assert_equal 0, sprite.width
  assert_equal 0, sprite.height

  bmp = RGSS::Bitmap.new(40, 24)
  sprite.instance_variable_set(:@bitmap, bmp)
  assert_equal 40, sprite.width
  assert_equal 24, sprite.height
end

assert "RGSS::Font defaults" do
  f = RGSS::Font.new
  assert_equal RGSS::Font.default_name, f.name
  assert_equal RGSS::Font.default_size, f.size
  assert_true f.color.is_a?(RGSS::Color)
  assert_true RGSS::Font.exist?("Arial")
end

# draw_text/text_size read the whole Font (name, size, bold, italic, outline,
# shadow, colours) to pick a TrueType face and lay text out. No game font file
# is reachable under the test's empty GAME_DIR/RTP_DIR, so drawing falls back to
# the built-in shinonome bitmap font; these checks cover that fallback and the
# Font-attribute plumbing the TrueType path shares.
assert "RGSS::Bitmap#draw_text renders in the font colour" do
  b = RGSS::Bitmap.new(64, 24)
  b.font.color = RGSS::Color.new(255, 0, 0, 255)
  b.draw_text(0, 0, 64, 24, "Hi")

  drawn = nil
  0.upto(23) do |y|
    0.upto(63) do |x|
      px = b.get_pixel(x, y)
      if px.alpha > 0
        drawn = px
        break
      end
    end
    break if drawn
  end
  assert_true !drawn.nil?, "draw_text drew no pixels"
  assert_equal 255.0, drawn.red
  assert_equal 0.0, drawn.green
  assert_equal 0.0, drawn.blue
end

# RGSS overloads #draw_text: a Rect stands in for x/y/width/height, the way
# #fill_rect takes either. It is not a nicety — `Window_Command#draw_item`, the
# menu every RPG Maker XP title screen is built from, calls
# `contents.draw_text(rect, text)` — so with only the four-number form a game's
# own engine died at its first window ("wrong number of arguments (given 2,
# expected 5..6)"), which is how the script-host boot check found this.
assert "RGSS::Bitmap#draw_text takes a Rect as well as x/y/width/height" do
  pixels = lambda do |bitmap|
    seen = []
    0.upto(bitmap.height - 1) do |y|
      0.upto(bitmap.width - 1) do |x|
        seen.push([x, y]) if bitmap.get_pixel(x, y).alpha > 0
      end
    end
    seen
  end

  numbers = RGSS::Bitmap.new(64, 24)
  numbers.draw_text(8, 4, 40, 16, "Hi", 1)
  rect = RGSS::Bitmap.new(64, 24)
  assert_equal rect, rect.draw_text(RGSS::Rect.new(8, 4, 40, 16), "Hi", 1)

  drawn = pixels.call(rect)
  assert_true drawn.size > 0, "the Rect form drew nothing"
  assert_equal pixels.call(numbers), drawn,
               "the Rect form drew somewhere else than x/y/width/height"

  # Without an align argument, as Window_Command calls it.
  plain = RGSS::Bitmap.new(64, 24)
  plain.draw_text(RGSS::Rect.new(0, 0, 64, 24), "Hi")
  assert_true pixels.call(plain).size > 0, "the 2-argument Rect form drew nothing"
end

# Real RGSS3 accepts any object as the text argument, not just a String --
# games routinely draw_text an Integer directly (HP/MP/gold, the way this
# real VX Ace release's own stock Window_Gold#refresh ->
# #draw_currency_value calls `draw_text(x, y, w, h, $game_party.gold, 2)`),
# relying on implicit #to_s. Both call-signature branches this coerces in.
assert "RGSS::Bitmap#draw_text accepts a non-String text argument" do
  numbers = RGSS::Bitmap.new(64, 24)
  assert_equal numbers, numbers.draw_text(0, 0, 64, 24, 42)

  via_rect = RGSS::Bitmap.new(64, 24)
  assert_equal via_rect, via_rect.draw_text(RGSS::Rect.new(0, 0, 64, 24), 42)
end

# The fallback for projects that ship no font. RGSS.default_font_path finds the
# bundled default font (assets/fonts) — downloaded rather than committed, so nil
# is a normal answer here — and Font.default_path is the opt-in switch each
# maker's boot flips.
#
# With it unset, Font#size must not move the measurement at all: the bitmap font
# has exactly one size, and that is what keeps RPG2000 on RPG_RT's metrics.
assert "RGSS::Font.default_path is opt-in" do
  path = RGSS.default_font_path
  assert_true path.nil? || (path.is_a?(String) && !path.empty?)

  saved = RGSS::Font.default_path
  begin
    RGSS::Font.default_path = nil
    b = RGSS::Bitmap.new(64, 40)
    b.font.size = 12
    small = b.text_size("Hi").height
    b.font.size = 40
    assert_equal small, b.text_size("Hi").height
  ensure
    RGSS::Font.default_path = saved
  end
end

# Set, it takes over: the same text at 40px now measures taller than at 12px,
# because it is being rasterised from real outlines. Skipped when no default
# font is installed; the check above still covers the plumbing.
assert "RGSS::Font.default_path drives text_size when set" do
  path = RGSS.default_font_path
  if path
    saved = RGSS::Font.default_path
    begin
      RGSS::Font.default_path = path
      b = RGSS::Bitmap.new(64, 64)
      b.font.size = 12
      small = b.text_size("Hi").height
      b.font.size = 40
      big = b.text_size("Hi").height
      assert_true big > small,
                  "expected the fallback font to scale with Font#size " \
                  "(40px measured #{big}, 12px measured #{small})"
    ensure
      # Leave it as it was: the checks below expect the shinonome path.
      RGSS::Font.default_path = saved
    end
  end
end

assert "RGSS::Bitmap#draw_text honours every Font attribute without error" do
  b = RGSS::Bitmap.new(80, 24)
  b.font.bold = true
  b.font.italic = true
  b.font.outline = true
  b.font.shadow = true
  b.font.out_color = RGSS::Color.new(0, 0, 0, 128)
  # An array of family names is accepted (RGSS allows it); must not raise.
  b.font.name = ["Nonexistent Family", "Arial"]
  assert_equal b, b.draw_text(0, 0, 80, 24, "Ok", 1)
end

assert "RGSS::Bitmap#text_size measures ASCII text" do
  b = RGSS::Bitmap.new(64, 24)
  r = b.text_size("Hello")
  assert_true r.is_a?(RGSS::Rect)
  assert_true r.width > 0, "text_size width should be positive"
  assert_true r.height > 0, "text_size height should be positive"
  assert_equal 0, b.text_size("").width
end

assert "RGSS::Bitmap loads RPG Maker XYZ images" do
  # A 3x2 XYZ picture: "XYZ1" + uint16 LE width/height + a zlib stream holding
  # a 768-byte RGB palette then one index per pixel. Palette 0 = (10,20,30),
  # 1 = (255,0,0), 2 = (0,255,0); pixels are 0,1,2 / 2,1,0.
  bytes = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
          "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
          "\x8b\x02\x41"
  path = "test-windowskin.xyz"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    b = RGSS::Bitmap.new(path)
    assert_equal 3, b.width
    assert_equal 2, b.height
    # Top-left pixel is palette index 0 -> (10, 20, 30), opaque.
    px = b.get_pixel(0, 0)
    assert_equal 10.0, px.red
    assert_equal 20.0, px.green
    assert_equal 30.0, px.blue
    assert_equal 255.0, px.alpha
    # (1,0) is palette index 1 (red), (2,0) is index 2 (green).
    assert_equal 255.0, b.get_pixel(1, 0).red
    assert_equal 255.0, b.get_pixel(2, 0).green
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap keys the XYZ transparent colour when requested" do
  bytes = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
          "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
          "\x8b\x02\x41"
  path = "test-windowskin-trans.xyz"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    b = RGSS::Bitmap.new(path, true)
    # Palette index 0 becomes fully transparent, other indices stay opaque.
    assert_equal 0.0, b.get_pixel(0, 0).alpha
    assert_equal 255.0, b.get_pixel(1, 0).alpha
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap decodes XYZ pixels stored as raw DEFLATE" do
  # Same 3x2 picture, but the payload is raw DEFLATE with no 2-byte zlib
  # header; stb's default zlib client rejects it, so this exercises the
  # no-header inflate fallback.
  bytes = "\x58\x59\x5a\x31\x03\x00\x02\x00\xe3\x12\x91\xfb\xcf\xc0\xc0\x00" \
          "\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00"
  path = "test-windowskin-raw.xyz"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    b = RGSS::Bitmap.new(path)
    assert_equal 3, b.width
    assert_equal 255.0, b.get_pixel(1, 0).red
    assert_equal 255.0, b.get_pixel(2, 0).green
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap reports a detailed reason when an XYZ fails to decode" do
  # Valid "XYZ1" header and zlib header byte, but a corrupt DEFLATE body.
  bytes = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xff\xff\xff\xff\xff\xff" \
          "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
  path = "test-windowskin-bad.xyz"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    err = nil
    begin
      RGSS::Bitmap.new(path)
    rescue => e
      err = e.message
    end
    assert_true !err.nil?, "expected a load failure"
    # The message carries the parsed dimensions so the failure is diagnosable.
    assert_true err.include?("XYZ 3x2"), "message: #{err}"
    assert_true RGSS::Bitmap._load_error.include?("XYZ 3x2")
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap reports a missing file as missing, not as the last decoder error" do
  # A name that matches nothing reaches no decoder, so the only diagnostics
  # available are the ones an *earlier* image left in stb's (never-cleared)
  # failure reason. Quoting those is worse than saying nothing: stb tries JPEG
  # first and its header check fails on a PNG's magic without being cleared by
  # the PNG's later success, so after any successful PNG the stale reason is
  # "no SOI" — and every missing asset in a PNG game (a released project's RTP
  # references, above all) was reported as a JPEG complaint about a file that
  # was never opened.
  #
  # The successful load first is what makes this an A/B: without it there is no
  # stale reason to leak and the second half passes vacuously.
  bytes = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" \
          "\x00\x00\x00\x04\x00\x00\x00\x01\x08\x00\x00\x00\x00\xdc\x57\x50" \
          "\x11\x00\x00\x00\x0b\x49\x44\x41\x54\x78\x01\x63\x00\x62\x4e\x00" \
          "\x00\x0e\x00\x0a\x61\xd4\xa9\x6f\x00\x00\x00\x00\x49\x45\x4e\x44" \
          "\xae\x42\x60\x82"
  path = "test-stale-reason.png"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    RGSS::Bitmap.new(path)
    stale = RGSS::Bitmap._stbi_error
    assert_true !stale.empty?, "expected stb to leave a reason behind"

    err = nil
    begin
      RGSS::Bitmap.new("Graphics/Characters/023-Gunner01")
    rescue => e
      err = e.message
    end
    assert_true !err.nil?, "expected a load failure"
    assert_false RGSS::Bitmap._decoder_ran?, "nothing should have been decoded"
    assert_true err.include?("not found"), "message: #{err}"
    # The actionable part: which search root came up empty. Here (and in a
    # packed release with no RTP installed) that is the RTP.
    assert_true err.include?("RTP"), "message: #{err}"
    assert_false err.include?(stale), "message quotes a stale reason: #{err}"
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap::LoadError carries the path and reason apart" do
  # RPG::Cache logs the file it is standing a blank bitmap in for, so it needs
  # the reason without the path in front of it — the two used to be available
  # only glued together in the message, and the log said the path twice.
  err = nil
  begin
    RGSS::Bitmap.new("Graphics/Characters/023-Gunner01")
  rescue RGSS::Bitmap::LoadError => e
    err = e
  end
  assert_true !err.nil?, "expected a Bitmap::LoadError"
  assert_equal "Graphics/Characters/023-Gunner01", err.path
  assert_true err.reason.include?("not found"), "reason: #{err.reason}"
  assert_false err.reason.include?(err.path), "reason repeats the path"
  # Still a RuntimeError, which is what `rescue` clauses around Bitmap.new (and
  # the assert_raise below) have always caught.
  assert_true err.kind_of?(RuntimeError)
end

# ---- Loading assets out of an encrypted archive ---------------------------
#
# A released RPG Maker game packs its whole Graphics/ tree into Game.rgssad /
# .rgss2a / .rgss3a with nothing loose on disk, so the loose-file search finds
# nothing and every asset has to come out of the archive. The reader itself is
# RPGXP::RGSSAD (tested in mruby-rpgxp, which also covers the end-to-end path);
# what is checked here is mruby-rgss's half — that Bitmap consults whatever is
# registered as RGSS.asset_archive, tries the same extension candidates the
# loose search does, and decodes the bytes through the same decoders.
#
# The fixture is the 3x2 XYZ picture used above: palette 0 = (10,20,30),
# 1 = red, 2 = green.
XYZ_3X2 = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
          "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
          "\x8b\x02\x41"

# Stands in for an RPGXP::RGSSAD: anything answering read(name) -> String or
# nil will do. Records its lookups so the candidate order can be asserted.
class FakeArchive
  def initialize(entries)
    @entries = entries
    @asked = []
  end

  attr_reader :asked

  def read(name)
    @asked << name
    @entries[name]
  end
end

assert "RGSS::Bitmap decodes packed bytes exactly as it decodes a file" do
  # Same picture, same expectations as the loose-file XYZ tests above — the two
  # paths share one decoder (bmp_decode_into), and this is what pins that.
  archive = FakeArchive.new({ "Graphics/System/Window" => XYZ_3X2 })
  RGSS.asset_archive = archive
  begin
    b = RGSS::Bitmap.new("Graphics/System/Window")
    assert_equal 3, b.width
    assert_equal 2, b.height
    px = b.get_pixel(0, 0)
    assert_equal 10.0, px.red
    assert_equal 20.0, px.green
    assert_equal 30.0, px.blue
    assert_equal 255.0, px.alpha
    assert_equal 255.0, b.get_pixel(1, 0).red
    assert_equal 255.0, b.get_pixel(2, 0).green
    # The transparent-colour flag reaches the packed path too.
    t = RGSS::Bitmap.new("Graphics/System/Window", true)
    assert_equal 0.0, t.get_pixel(0, 0).alpha
    assert_equal 255.0, t.get_pixel(1, 0).alpha
  ensure
    RGSS.asset_archive = nil
  end
end

assert "RGSS::Bitmap reports undecodable packed bytes instead of crashing" do
  archive = FakeArchive.new({ "Graphics/System/Junk" => "not an image at all" })
  RGSS.asset_archive = archive
  begin
    assert_raise(RuntimeError) { RGSS::Bitmap.new("Graphics/System/Junk") }
  ensure
    RGSS.asset_archive = nil
  end
end

assert "RGSS::Bitmap loads a packed asset through RGSS.asset_archive" do
  archive = FakeArchive.new({ "Graphics/System/Window.xyz" => XYZ_3X2 })
  RGSS.asset_archive = archive
  begin
    b = RGSS::Bitmap.new("Graphics/System/Window")
    assert_equal 3, b.width
    assert_equal 255.0, b.get_pixel(2, 0).green
    # The bare name is tried before the extension candidates, exactly as the
    # loose-file search does it.
    assert_equal "Graphics/System/Window", archive.asked.first
    assert_true archive.asked.include?("Graphics/System/Window.xyz")
  ensure
    RGSS.asset_archive = nil
  end
end

assert "RGSS::Bitmap prefers a loose file over the archive" do
  # RGSS lets a loose file shadow the packed entry; the archive must not even be
  # consulted when one is found. The loose copy here is the raw-DEFLATE spelling
  # of the same picture, so a wrong pick still decodes and only `asked` tells
  # them apart.
  loose = "\x58\x59\x5a\x31\x03\x00\x02\x00\xe3\x12\x91\xfb\xcf\xc0\xc0\x00" \
          "\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00"
  path = "test-packed-shadow.xyz"
  File.open(path, "wb") { |io| io.write(loose) }
  archive = FakeArchive.new({ path => XYZ_3X2 })
  RGSS.asset_archive = archive
  begin
    b = RGSS::Bitmap.new(path)
    assert_equal 3, b.width
    assert_true archive.asked.empty?, "archive was consulted: #{archive.asked}"
  ensure
    RGSS.asset_archive = nil
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap still raises its own diagnostic when the archive misses" do
  archive = FakeArchive.new({})
  RGSS.asset_archive = archive
  begin
    err = nil
    begin
      RGSS::Bitmap.new("Graphics/System/Missing")
    rescue => e
      err = e.message
    end
    assert_true !err.nil?, "expected a load failure"
    assert_true err.include?("Graphics/System/Missing"), "message: #{err}"
  ensure
    RGSS.asset_archive = nil
  end
end

assert "RGSS::Bitmap survives an archive that raises" do
  # A corrupt archive must not turn a missing-asset error into a crash: the read
  # failure is reported and treated as a miss, so the loader's own diagnostic is
  # what reaches the caller.
  broken = Object.new
  def broken.read(_name)
    raise "archive is corrupt"
  end
  RGSS.asset_archive = broken
  begin
    assert_raise(RuntimeError) { RGSS::Bitmap.new("Graphics/System/Window") }
  ensure
    RGSS.asset_archive = nil
  end
end

assert "RGSS::Profiler is inert until enabled" do
  # The standalone test binary never calls profiler_configure, so profiling is
  # off by default: query methods report the disabled state and the block-timing
  # helpers still run their block and return its value transparently.
  assert_false RGSS::Profiler.enabled?
  assert_nil RGSS::Profiler.stats

  ran = false
  result = RGSS::Profiler.section("noop") do
    ran = true
    123
  end
  assert_true ran, "section must always run its block"
  assert_equal 123, result

  ran = false
  result = RGSS::Profiler.frame do
    ran = true
    "ok"
  end
  assert_true ran, "frame must always run its block"
  assert_equal "ok", result
end

assert "RGSS::Profiler aggregates frames and sections when enabled" do
  RGSS::Profiler.enabled = true
  begin
    RGSS::Profiler.reset
    assert_true RGSS::Profiler.enabled?

    3.times do
      RGSS::Profiler.frame do
        RGSS::Profiler.section("work") { 100.times { |i| i * i } }
      end
    end

    st = RGSS::Profiler.stats
    assert_true st.is_a?(Hash)
    assert_equal 3, st[:frames]
    assert_true st[:fps] >= 0.0
    assert_true st[:frame_avg_ms] >= 0.0
    # No frame missed its fps-cap deadline here (there is no Graphics.update
    # pacing in this standalone test binary), so the drop count stays at 0.
    assert_equal 0, st[:frame_drops]

    sections = st[:sections]
    assert_true sections.is_a?(Hash)
    assert_true sections.key?("work"), "expected a 'work' section"
    assert_equal 3, sections["work"][:calls]
    assert_true sections["work"][:avg_ms] >= 0.0

    # report and reset must not raise; reset clears the interval.
    RGSS::Profiler.report
    RGSS::Profiler.reset
    assert_equal 0, RGSS::Profiler.stats[:frames]
  ensure
    RGSS::Profiler.enabled = false
  end
end

assert "RGSS::Profiler streams a Chrome trace" do
  path = "test-profiler-trace.json"
  File.delete(path) if File.exist?(path)
  begin
    assert_false RGSS::Profiler.tracing?
    RGSS::Profiler.trace_start(path)
    assert_true RGSS::Profiler.tracing?
    assert_true RGSS::Profiler.enabled?  # tracing implies profiling

    3.times do
      RGSS::Profiler.frame do
        RGSS::Profiler.section("unit.work") { 50.times { |i| i * i } }
      end
    end

    RGSS::Profiler.trace_stop
    assert_false RGSS::Profiler.tracing?

    json = File.open(path, "r") { |f| f.read }
    # A well-formed Chrome Trace Event array with the frame and section events.
    assert_true json.start_with?("["), "trace must be a JSON array"
    assert_true json.include?("\"ph\":\"X\""), "expected duration events"
    assert_true json.include?("unit.work"), "expected the section name"
    assert_true json.include?("\"name\":\"frame\""), "expected frame events"
  ensure
    RGSS::Profiler.trace_stop
    RGSS::Profiler.enabled = false
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Audio primitives are inert without a backend" do
  # The standalone test binary installs no audio backend (that lives in the
  # executable, src/sdl_audio.cxx), so every native primitive is a safe no-op.
  assert_nil RGSS::Audio._bgm_play("nope", 80, 90)
  assert_nil RGSS::Audio._bgm_volume(50)
  assert_nil RGSS::Audio._bgm_pan(50)
  assert_nil RGSS::Audio._bgm_stop
  assert_nil RGSS::Audio._bgm_fade(100)
  assert_equal 0, RGSS::Audio._bgm_pos
  assert_nil RGSS::Audio._bgs_play("nope")
  assert_nil RGSS::Audio._bgs_stop
  assert_nil RGSS::Audio._bgs_fade(100)
  assert_equal 0, RGSS::Audio._bgs_pos
  assert_nil RGSS::Audio._me_play("nope")
  assert_nil RGSS::Audio._me_stop
  assert_nil RGSS::Audio._me_fade(100)
  assert_nil RGSS::Audio._se_play("nope")
  assert_nil RGSS::Audio._se_stop
  assert_nil RGSS::Audio._update
  # The same for the memory entry points, and _can_play_mem? reports the
  # backend's absence so the Ruby layer can say a packed game will be silent
  # instead of dropping every play without a word.
  assert_nil RGSS::Audio._bgm_play_mem("nope", "bytes")
  assert_nil RGSS::Audio._bgs_play_mem("nope", "bytes")
  assert_nil RGSS::Audio._me_play_mem("nope", "bytes")
  assert_nil RGSS::Audio._se_play_mem("nope", "bytes")
  assert_false RGSS::Audio._can_play_mem?
end

# ---- Playing audio out of an encrypted archive ----------------------------
#
# A released game packs its whole Audio/ tree into Game.rgssad / .rgss2a /
# .rgss3a with nothing loose, so the disk search finds nothing and every track
# has to come out of the archive. Whether the bytes then reach the mixer is
# native and unobservable here (this binary installs no audio backend) — that is
# what the `audio_probe` ctest measures. What is checked here is the Ruby half:
# which archive names are tried, in what order, and that a loose file still wins.
assert "RGSS::Audio plays a packed track through RGSS.asset_archive" do
  wav = "RIFFtestWAVEfixture"
  archive = FakeArchive.new({ "Audio/BGM/Theme1.ogg" => wav })
  class << RGSS::Audio
    alias _bgm_play_mem_orig _bgm_play_mem
    alias _can_play_mem_orig _can_play_mem?
    def _bgm_play_mem(name, bytes, volume, pitch, pos = 0)
      $audio_mem_capture = [name, bytes, volume, pitch, pos]
      nil
    end
    # No backend is installed in this binary, so pretend one is: without it the
    # loader would (correctly) report that it cannot play packed audio here.
    def _can_play_mem? = true
  end
  RGSS.asset_archive = archive
  begin
    $audio_mem_capture = nil
    RGSS::Audio.bgm_play("Theme1", 80, 90)
    assert_false $audio_mem_capture.nil?, "expected the packed BGM to play"
    # The entry name found, not the bare name the game asked for — the folder
    # and extension are the loader's doing.
    assert_equal "Audio/BGM/Theme1.ogg", $audio_mem_capture[0]
    assert_equal wav, $audio_mem_capture[1]
    assert_equal 80, $audio_mem_capture[2]
    assert_equal 90, $audio_mem_capture[3]
    # BGM looks in Audio/BGM before anywhere else.
    assert_equal "Audio/BGM/Theme1", archive.asked.first

    # A name in no folder of the archive plays nothing at all.
    $audio_mem_capture = nil
    RGSS::Audio.bgm_play("NoSuchTrack")
    assert_true $audio_mem_capture.nil?, "a missing entry must not play"
  ensure
    RGSS.asset_archive = nil
    class << RGSS::Audio
      alias _bgm_play_mem _bgm_play_mem_orig
      alias _can_play_mem? _can_play_mem_orig
    end
  end
end

assert "RGSS::Audio prefers a loose file over the archive" do
  # As with Bitmap: loose shadows packed, which is what RGSS does. The archive
  # must not even be consulted when a file resolves.
  path = "test-packed-se.wav"
  File.open(path, "wb") { |io| io.write("RIFFtestWAVEfixture") }
  archive = FakeArchive.new({ "Audio/SE/test-packed-se.wav" => "packed" })
  class << RGSS::Audio
    alias _se_play_orig2 _se_play
    def _se_play(p, v, pi)
      $audio_se_capture = [p, v, pi]
      nil
    end
  end
  RGSS.asset_archive = archive
  begin
    $audio_se_capture = nil
    RGSS::Audio.se_play("test-packed-se")
    assert_equal "test-packed-se.wav", $audio_se_capture[0]
    assert_true archive.asked.empty?, "archive was consulted: #{archive.asked}"
  ensure
    RGSS.asset_archive = nil
    class << RGSS::Audio
      alias _se_play _se_play_orig2
    end
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Audio finds an upper-case extension on disk" do
  # RPG Maker games were authored on Windows, whose filesystem does not
  # distinguish `.MID` from `.mid`, so a released game mixes both spellings in
  # one folder (Pray for You's Audio/BGM holds ten `.MID` beside eight `.mid`).
  # A lower-case-only search made the upper-case half unplayable on a
  # case-sensitive filesystem, reported as "no BGM found" for a file that is
  # right there.
  path = "test-upper-se.WAV"
  File.open(path, "wb") { |io| io.write("RIFFtestWAVEfixture") }
  class << RGSS::Audio
    alias _se_play_orig3 _se_play
    def _se_play(p, v, pi)
      $audio_se_capture = [p, v, pi]
      nil
    end
  end
  begin
    $audio_se_capture = nil
    RGSS::Audio.se_play("test-upper-se")
    assert_false $audio_se_capture.nil?, "the .WAV should have resolved"
    assert_equal path, $audio_se_capture[0]
  ensure
    class << RGSS::Audio
      alias _se_play _se_play_orig3
    end
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Audio skips a directory that shadows a track name" do
  # EXT_SPELLINGS leads with the empty extension and MUSIC_DIRS/SOUND_DIRS with
  # the empty folder, so the first candidate for a track called "X" is the bare
  # name "X" under the game root -- exactly where a released game keeps its
  # asset *folders*. Nepheshel ships `Title/` (title-screen graphics) beside
  # `Music/title.mid`, and on a case-insensitive filesystem that folder matched
  # the bare candidate first: the search stopped on a directory, handed it to
  # Mix_LoadMUS, and the title MIDI was silent ("failed to load music
  # '.../title'") for a file sitting right there in Music/. A directory is never
  # a playable asset.
  dir = "test-shadowed-se"
  path = "test-shadowed-se.wav"
  Dir.mkdir(dir) unless Dir.exist?(dir)
  File.open(path, "wb") { |io| io.write("RIFFtestWAVEfixture") }
  class << RGSS::Audio
    alias _se_play_orig4 _se_play
    def _se_play(p, v, pi)
      $audio_se_capture = [p, v, pi]
      nil
    end
  end
  begin
    $audio_se_capture = nil
    RGSS::Audio.se_play("test-shadowed-se")
    assert_false $audio_se_capture.nil?, "the .wav should have resolved"
    assert_equal path, $audio_se_capture[0]
  ensure
    class << RGSS::Audio
      alias _se_play _se_play_orig4
    end
    File.delete(path) if File.exist?(path)
    Dir.delete(dir) if Dir.exist?(dir)
  end
end

assert "RGSS::Audio finds an upper-case extension in the archive" do
  # The same for a packed release: an archive entry name is whatever the editor
  # wrote, so it carries the same mixed-case extensions the disk tree does.
  archive = FakeArchive.new({ "Audio/BGM/Theme2.MID" => "MThd-fixture" })
  class << RGSS::Audio
    alias _bgm_play_mem_orig2 _bgm_play_mem
    alias _can_play_mem_orig2 _can_play_mem?
    def _bgm_play_mem(name, bytes, volume, pitch, pos = 0)
      $audio_mem_capture = [name, bytes, volume, pitch, pos]
      nil
    end
    def _can_play_mem? = true
  end
  RGSS.asset_archive = archive
  begin
    $audio_mem_capture = nil
    RGSS::Audio.bgm_play("Theme2")
    assert_false $audio_mem_capture.nil?, "the .MID entry should have resolved"
    assert_equal "Audio/BGM/Theme2.MID", $audio_mem_capture[0]
  ensure
    RGSS.asset_archive = nil
    class << RGSS::Audio
      alias _bgm_play_mem _bgm_play_mem_orig2
      alias _can_play_mem? _can_play_mem_orig2
    end
  end
end

assert "RGSS::Audio says so when it cannot play packed audio" do
  # A build with no audio backend must not swallow the play silently: the
  # loader reports it once through warn_stub. Checked by observing that the
  # native primitive is never reached while the entry *was* found.
  archive = FakeArchive.new({ "Audio/SE/Beep.wav" => "RIFFtestWAVEfixture" })
  RGSS.asset_archive = archive
  begin
    RGSS::Audio.se_play("Beep")
    assert_true archive.asked.include?("Audio/SE/Beep.wav"),
                "the entry should have been found: #{archive.asked}"
  ensure
    RGSS.asset_archive = nil
  end
end

assert "RGSS::Audio survives an archive that raises" do
  broken = Object.new
  def broken.read(_name)
    raise "archive is corrupt"
  end
  RGSS.asset_archive = broken
  begin
    assert_nil RGSS::Audio.bgm_play("Theme1")
  ensure
    RGSS.asset_archive = nil
  end
end

# RGSS3's own `pos` argument (VX Ace added it over XP/VX's 3-argument form),
# used to resume a BGM from where a prior track left off -- a real VX Ace
# volume-control add-on calls `Audio.bgm_play(name, vol, pitch, pos)`
# directly, and the 4th argument raised ArgumentError before this method
# accepted it.
assert "RGSS::Audio.bgm_play accepts RGSS3's 4th (pos) argument" do
  assert_nil RGSS::Audio.bgm_play("Theme1", 80, 90, 5)
end

# Same RGSS3 4th (pos) argument as bgm_play above, but real stock RPG::BGS#play
# passes it too -- BGS has no seekable backend to honour it with (unlike BGM,
# its playback is a one-shot sample channel), so unlike bgm_play this accepts
# and ignores a nonzero pos rather than raising ArgumentError on every VX Ace
# game whose event system plays a BGS the stock way.
assert "RGSS::Audio.bgs_play accepts RGSS3's 4th (pos) argument" do
  assert_nil RGSS::Audio.bgs_play("Theme1", 80, 90, 5)
end

assert "RGSS::Audio.se_play resolves a name to a real file" do
  # Capture what the public API forwards to the native primitive so we can
  # assert the filename was resolved (extension appended) and volume/pitch
  # passed through.
  path = "test-se-fixture.wav"
  File.open(path, "wb") { |io| io.write("RIFFtestWAVEfixture") }
  class << RGSS::Audio
    alias _se_play_orig _se_play
    def _se_play(p, v, pi)
      $audio_se_capture = [p, v, pi]
      nil
    end
  end
  begin
    $audio_se_capture = nil
    RGSS::Audio.se_play("test-se-fixture", 80, 90)
    assert_false $audio_se_capture.nil?, "expected _se_play to be called"
    assert_equal "test-se-fixture.wav", $audio_se_capture[0]
    assert_equal 80, $audio_se_capture[1]
    assert_equal 90, $audio_se_capture[2]

    # A name that resolves to nothing skips the native call entirely.
    $audio_se_capture = nil
    RGSS::Audio.se_play("no-such-sound-effect")
    assert_true $audio_se_capture.nil?, "unresolved name must not play"
  ensure
    class << RGSS::Audio
      alias _se_play _se_play_orig
    end
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap loads a PNG whose deflate stream trips \"bad dist\"" do
  # A 4x1 grayscale PNG hand-encoded so its IDAT references a zero pre-history
  # window (distance-too-far-back). stb_image and strict zlib reject it with
  # "bad dist"; the tolerant fallback resolves the out-of-range reference to
  # zeros. Pixels decode to grayscale 0, 0, 0, 9.
  bytes = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" \
          "\x00\x00\x00\x04\x00\x00\x00\x01\x08\x00\x00\x00\x00\xdc\x57\x50" \
          "\x11\x00\x00\x00\x0b\x49\x44\x41\x54\x78\x01\x63\x00\x62\x4e\x00" \
          "\x00\x0e\x00\x0a\x61\xd4\xa9\x6f\x00\x00\x00\x00\x49\x45\x4e\x44" \
          "\xae\x42\x60\x82"
  path = "test-baddist.png"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    b = RGSS::Bitmap.new(path)
    assert_equal 4, b.width
    assert_equal 1, b.height
    assert_equal 0.0, b.get_pixel(0, 0).red
    assert_equal 9.0, b.get_pixel(3, 0).red
    assert_equal 255.0, b.get_pixel(3, 0).alpha
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Plane API surface" do
  # Plane is now native: Plane.new builds an lv_canvas the size of the viewport
  # and tiles the bitmap into it, so construction needs a live display the
  # headless test binary lacks. Assert only the method surface here (the tiling
  # itself is exercised by the game runs), matching the Viewport/Sprite tests.
  %i[bitmap= ox= oy= opacity= tone= color= blend_type= zoom_x= zoom_y= z=
     visible visible= dispose disposed?].each do |m|
    assert_true RGSS::Plane.method_defined?(m), "Plane##{m} missing"
  end
end

assert "RGSS::Window API surface" do
  # Window is now native: Window.new builds an lv_canvas the size of the window
  # and blits the contents into it, so construction needs a live display the
  # headless test binary lacks. Assert only the method surface here (the
  # compositing itself is exercised by the game runs), matching Sprite/Plane. The
  # still-Ruby deferred accessors (windowskin, cursor_rect, opacity,
  # back_opacity, active, pause, stretch) are covered by being defined below.
  %i[contents= x= y= width= height= ox= oy= contents_opacity= z= visible
     visible= dispose disposed? windowskin windowskin= cursor_rect cursor_rect=
     opacity opacity= back_opacity back_opacity= cursor_rect= active active=
     pause pause= stretch stretch= update].each do |m|
    assert_true RGSS::Window.method_defined?(m), "Window##{m} missing"
  end
end

assert "RGSS::Input registers a tap that pressed and released in one frame" do
  # Key transitions reach Input through a buffer drained once a frame, so a
  # quick tap -- a browser keypad button, a synthesised key -- can deliver both
  # its press and its release before the game looks. The trigger must survive
  # to that look, and the key must read as no longer held.
  begin
    RGSS::Input.update
    RGSS::Input.press(RGSS::Input::C)
    RGSS::Input.release(RGSS::Input::C)
    assert_true RGSS::Input.trigger?(RGSS::Input::C), "the tap must register"
    assert_false RGSS::Input.press?(RGSS::Input::C), "and must not read as held"
    # ... and only for the one frame.
    RGSS::Input.update
    assert_false RGSS::Input.trigger?(RGSS::Input::C)
  ensure
    RGSS::Input.release(RGSS::Input::C)
    RGSS::Input.update
  end
end

# The order inside Input.update is what makes a game's own engine playable. An
# RGSS scene loop reads input *after* calling Input.update:
#
#   loop { Graphics.update; Input.update; update; break if $scene != self }
#
# so a transition applied anywhere before that Input.update — which is where the
# backends' buffer used to be drained, in Graphics.update — was wiped by it
# before the scene ever looked. `Input.trigger?` was permanently false for a game
# running under the script host: no New Game, no message advance, no menu.
# Input.update now expires the old triggers, *then* drains the buffer.
assert "RGSS::Input.update applies buffered keys, so a scene loop sees them" do
  begin
    RGSS::Input.update
    # A key arrives between frames, exactly as the SDL event watch buffers it.
    RGSS::Input._push(RGSS::Input::C, true)
    # The scene loop's Input.update. (Graphics.update needs a live display the
    # test binary lacks — and no longer touches input, which is the fix.)
    RGSS::Input.update
    assert_true RGSS::Input.trigger?(RGSS::Input::C),
                "the game's own Input.update swallowed the key"
    assert_true RGSS::Input.press?(RGSS::Input::C), "the key should read as held"
    # A trigger still lives exactly one frame; the hold outlasts it.
    RGSS::Input.update
    assert_false RGSS::Input.trigger?(RGSS::Input::C)
    assert_true RGSS::Input.press?(RGSS::Input::C)
    # And the release arrives the same way.
    RGSS::Input._push(RGSS::Input::C, false)
    RGSS::Input.update
    assert_false RGSS::Input.press?(RGSS::Input::C)
  ensure
    RGSS::Input.release(RGSS::Input::C)
    RGSS::Input.update
  end
end

assert "RGSS::Input accepts RGSS2/RGSS3 symbol keys" do
  # VX and VX Ace name the keys with symbols (Input.trigger?(:C)); XP and the
  # C++ input bridge use the integer constants. Both must reach the same key.
  begin
    RGSS::Input.press(RGSS::Input::C)
    assert_true RGSS::Input.press?(:C), "a symbol must read the integer press"
    assert_true RGSS::Input.trigger?(:C)
    RGSS::Input.release(:C)
    assert_false RGSS::Input.press?(RGSS::Input::C), "a symbol release must clear it"

    RGSS::Input.press(:UP)
    assert_true RGSS::Input.press?(RGSS::Input::UP), "a symbol press must set the key"
    assert_equal 8, RGSS::Input.dir4

    # Every RGSS3 key name maps, and an unknown one reads as unpressed instead
    # of raising out of the game loop.
    assert_equal 36, RGSS::Input::SYMBOL_KEYS.size
    RGSS::Input::SYMBOL_KEYS.each do |name, index|
      assert_equal index, RGSS::Input.key_index(name), "key #{name} maps wrong"
    end
    assert_false RGSS::Input.press?(:NO_SUCH_KEY)
    assert_nil RGSS::Input.release(:NO_SUCH_KEY)
  ensure
    RGSS::Input.release(:UP)
    RGSS::Input.release(:C)
  end
end

assert "RGSS::Input::N0..N9/PLUS..PERIOD are distinct ids continuing past F12" do
  # RPG2003's Key Input Processing Numbers/Operators groups (see
  # mruby-rpg2k's Scene::Map::NUMBER_KEY_BUTTONS/OPERATOR_KEY_BUTTONS): every
  # id must be its own slot so pressing one digit/operator never reads back
  # as another.
  digit_keys = [RGSS::Input::N0, RGSS::Input::N1, RGSS::Input::N2, RGSS::Input::N3,
                RGSS::Input::N4, RGSS::Input::N5, RGSS::Input::N6, RGSS::Input::N7,
                RGSS::Input::N8, RGSS::Input::N9]
  operator_keys = [RGSS::Input::PLUS, RGSS::Input::MINUS, RGSS::Input::MULTIPLY,
                    RGSS::Input::DIVIDE, RGSS::Input::PERIOD]
  all_keys = digit_keys + operator_keys
  assert_equal all_keys.uniq.size, all_keys.size, "every id must be distinct"
  assert_equal RGSS::Input::F12 + 1, RGSS::Input::N0, "ids continue right after F12"

  begin
    RGSS::Input.press(RGSS::Input::N3)
    assert_true RGSS::Input.press?(RGSS::Input::N3)
    assert_false RGSS::Input.press?(RGSS::Input::N4), "a different digit must stay unpressed"
    assert_false RGSS::Input.press?(RGSS::Input::PLUS), "an operator must stay unpressed"

    RGSS::Input.press(RGSS::Input::PERIOD)
    assert_true RGSS::Input.press?(:PERIOD), "the symbol spelling must reach the same id"
  ensure
    RGSS::Input.release(RGSS::Input::N3)
    RGSS::Input.release(RGSS::Input::PERIOD)
  end
end

# Graphics.brightness= drives a real Sprite/Bitmap (the fade overlay) since it
# actually draws now, and Sprite.new needs a live display the headless test
# binary lacks (see the Sprite/Tilemap note above) -- so every brightness=
# exercised as plain Ruby logic below stubs the private #brightness_sprite out
# for a fake that just remembers the opacity it was given, the same way other
# native calls are stubbed elsewhere in this file. The real overlay is
# exercised by RGSS.effect_probe (native, against a live display).
class << RGSS::Graphics
  alias _brightness_sprite_orig brightness_sprite
  def brightness_sprite
    return @fake_brightness_sprite if @fake_brightness_sprite
    o = Object.new
    def o.opacity=(v); @opacity = v; end
    @fake_brightness_sprite = o
  end
end

assert "RGSS::Graphics reports and resizes the screen" do
  # RGSS2 added Graphics.width/height; each maker's boot shell declares its own
  # resolution, and the stock VX Ace scripts compute camera and window layouts
  # from them.
  begin
    RGSS::Graphics.resize_screen(544, 416)
    assert_equal 544, RGSS::Graphics.width
    assert_equal 416, RGSS::Graphics.height

    assert_equal 255, RGSS::Graphics.brightness
    RGSS::Graphics.brightness = -5
    assert_equal 0, RGSS::Graphics.brightness
    RGSS::Graphics.brightness = 999
    assert_equal 255, RGSS::Graphics.brightness
  ensure
    RGSS::Graphics.resize_screen(640, 480)
    RGSS::Graphics.brightness = 255
  end
end

assert "RGSS::Graphics.wait / fadeout drive real frames" do
  # Graphics.update is native and needs a live display the headless test binary
  # lacks, so count the frames through a stand-in — what is under test is that
  # the RGSS2 waits run the frames the game's timing depends on.
  class << RGSS::Graphics
    alias _update_orig update
    def update
      $graphics_frames = ($graphics_frames || 0) + 1
      nil
    end
  end
  begin
    $graphics_frames = 0
    RGSS::Graphics.wait(3)
    assert_equal 3, $graphics_frames

    RGSS::Graphics.fadeout(2)
    assert_equal 5, $graphics_frames
    assert_equal 0, RGSS::Graphics.brightness

    RGSS::Graphics.fadein(1)
    assert_equal 6, $graphics_frames
    assert_equal 255, RGSS::Graphics.brightness
  ensure
    class << RGSS::Graphics
      alias update _update_orig
    end
    RGSS::Graphics.brightness = 255
  end
end

assert "RGSS::Audio.setup_midi is a safe no-op" do
  # RGSS2+; the VX/VX Ace scripts call it at boot when the project asks for
  # MIDI. The synth is configured when the audio device opens (src/sdl_audio.cxx
  # resolves assets/timidity or TIMIDITY_CFG), so there is nothing left to do.
  assert_nil RGSS::Audio.setup_midi
end

assert "RGSS::Audio.midi_available? is false without a backend" do
  # This binary installs no audio backend, so nothing can synthesise MIDI. The
  # query must say so rather than claim MIDI works and play silence.
  assert_false RGSS::Audio.midi_available?
end

# Minimal $stderr stand-in for the warn_once test below. It collects whole
# lines rather than capturing text and re-parsing it: mruby's String#scan comes
# from mruby-onig-regexp and takes a Regexp, not the String a literal search
# would want, so counting occurrences in captured output is a trap.
class WarnOnceSink
  attr_reader :lines

  def initialize
    @lines = []
  end

  def puts(message)
    @lines << message
  end

  # Not used by warn_once, but an object standing in for $stderr is expected to
  # be writable, and some runtimes reject one that is not.
  def write(text)
    @lines << text
    text.to_s.size
  end
end

assert "RGSS.warn_once reports each message only once" do
  # warn_stub is built on warn_once; both must stay quiet after the first call
  # so a per-frame caller cannot flood the log.
  sink = WarnOnceSink.new
  original = $stderr
  begin
    $stderr = sink
    RGSS.warn_once("warn-once-test-message")
    RGSS.warn_once("warn-once-test-message")
  ensure
    $stderr = original
  end
  assert_equal 1, sink.lines.size
  assert_equal "[RGSS] warn-once-test-message", sink.lines[0]
end

# RGSS::ErrorReport keeps the tail of the runtime log so a crash report can
# carry the messages that led up to the failure (src/error_dump.cxx). The same
# behaviour is checked on CRuby by scripts/error_report_check.rb, which can
# cover more of it; these assert it inside the built interpreter, where the
# String and Array methods the buffer leans on are the mruby ones.
assert "RGSS::ErrorReport records whole lines and bounds the buffer" do
  RGSS::ErrorReport.clear
  RGSS::ErrorReport.record("[RPG2k] split ")
  RGSS::ErrorReport.record("across writes\n")
  assert_equal ["[RPG2k] split across writes"], RGSS::ErrorReport.lines

  RGSS::ErrorReport.clear
  (RGSS::ErrorReport::MAX_LINES + 10).times { |i| RGSS::ErrorReport.record("line #{i}\n") }
  assert_equal RGSS::ErrorReport::MAX_LINES, RGSS::ErrorReport.lines.size
  assert_equal "line 10", RGSS::ErrorReport.lines[0]
  RGSS::ErrorReport.clear
end

assert "RGSS::ErrorReport.log_tail keeps an unterminated last line" do
  # The last thing a dying runtime logs is often the interesting line, and it
  # may never get its newline.
  RGSS::ErrorReport.clear
  RGSS::ErrorReport.record("[RPG2k] done\n")
  RGSS::ErrorReport.record("[RPG2k] mid-write")
  assert_equal "[RPG2k] done\n[RPG2k] mid-write\n", RGSS::ErrorReport.log_tail
  RGSS::ErrorReport.clear
end

assert "RGSS::ErrorReport::Tee forwards every write and records it" do
  RGSS::ErrorReport.clear
  sink = WarnOnceSink.new
  tee = RGSS::ErrorReport::Tee.new(sink)
  tee.puts "[RPG2k] through the tee"
  tee.write "[RPG2k] written\n"
  assert_equal ["[RPG2k] through the tee", "[RPG2k] written\n"], sink.lines
  assert_equal "[RPG2k] through the tee\n[RPG2k] written\n",
               RGSS::ErrorReport.log_tail
  RGSS::ErrorReport.clear
end

assert "RGSS::ErrorReport stamps a bridged line with the script's location" do
  # Every line the bridge forwards used to reach ng-log from the same C++
  # statement, so the whole runtime log was stamped "log_bridge.cxx:12" and said
  # nothing about which script logged what. RGSS.__log_bridge_write now reads
  # the location off the interpreter's call stack, skipping the tee's own frames
  # (record/push, both error_report.rb) -- so what it answers is *this* file and
  # the line that logged. mrbtest installs no ng-log hook, so the location it
  # reports is the only observable half of the forward here.
  RGSS::ErrorReport.clear
  expected_line = __LINE__ + 1
  RGSS::ErrorReport.record("[RGSS] location probe\n")
  loc = RGSS::ErrorReport.last_location
  assert_kind_of String, loc
  assert_true loc.include?("test.rb:"), "attributed to #{loc}"
  assert_equal expected_line, loc.split(":").last.to_i
  RGSS::ErrorReport.clear
end

assert "RGSS::ErrorReport.probe! raises after logging its marker line" do
  # The engine's --error_dump_probe drives this to check a real report keeps the
  # exception, its backtrace and the captured log; assert here that the probe
  # itself does what that check assumes.
  RGSS::ErrorReport.clear
  original = $stderr
  sink = WarnOnceSink.new
  raised = nil
  begin
    $stderr = RGSS::ErrorReport::Tee.new(sink)
    begin
      RGSS::ErrorReport.probe!
    rescue RuntimeError => e
      raised = e
    end
  ensure
    $stderr = original
  end
  assert_equal RGSS::ErrorReport::PROBE_MESSAGE, raised.message
  assert_equal [RGSS::ErrorReport::PROBE_LOG_LINE], RGSS::ErrorReport.lines
  RGSS::ErrorReport.clear
end

assert "RGSS::Window RGSS2/RGSS3 API surface" do
  # Window.new needs a live display (see the Tilemap note below), so assert the
  # VX/VX Ace surface is defined; what these accessors actually *draw* is
  # measured on a real display by RGSS.window_probe (the render_probe ctest).
  # The dual-form constructor (RGSS1's optional viewport / RGSS2's x, y, width,
  # height) needs no assertion here: it aliases the native initialize at load, so
  # a broken alias would fail the whole gem, not one test.
  %i[openness openness= open? close? padding padding= padding_bottom
     padding_bottom= arrows_visible arrows_visible= tone tone=].each do |m|
    assert_true RGSS::Window.method_defined?(m), "Window##{m} missing"
  end
  # `openness=`, `tone` and `tone=` must stay native: each redraws, and a
  # plain-Ruby accessor would store the value and animate nothing. mrblib loads
  # after the C init, so re-adding one there silently shadows the native and the
  # window stops opening. That cannot be told apart from here — this mruby has no
  # instance_method/source_location to ask with — so the guard is
  # RGSS.window_probe, which measures the area the window covers at three
  # openness values and fails if it does not change.
end

assert "RGSS::Viewport RGSS2/RGSS3 screen-effect surface" do
  # Viewport.new needs a live display the headless test binary lacks (see the
  # Tilemap note below), so assert the surface. `color`/`flash` draw a colour
  # overlay above the viewport's contents; `tone` is folded into each display
  # object's own composite (a tone rescales what is drawn, so it cannot be a
  # layer) — all native.
  %i[color color= flash tone tone= update ox oy rect rect= z= visible
     visible= dispose disposed?].each do |m|
    assert_true RGSS::Viewport.method_defined?(m), "Viewport##{m} missing"
  end
end

assert "RGSS::Graphics scene-transition surface" do
  # snap_to_bitmap grabs the rendered screen, so it needs a live display the
  # headless test binary lacks — as do freeze/transition, which are built on it.
  # What *can* be checked here is that they exist and that the natives are not
  # shadowed: mrblib loads after the C init, so a stray Ruby-side definition of
  # snap_to_bitmap would silently replace the real one (the mistake that had to
  # be undone for Viewport#tone). Actually drawing them is measured on a real
  # display by the `render_probe` ctest — see RGSS.effect_probe.
  %i[snap_to_bitmap freeze transition wait fadeout fadein update].each do |m|
    assert_true RGSS::Graphics.respond_to?(m), "Graphics.#{m} missing"
  end
  %i[frame_mean effect_probe].each do |m|
    assert_true RGSS.respond_to?(m), "RGSS.#{m} missing"
  end
  # The frozen still has to sit above anything a game sets, and RGSS z values
  # are plain integers.
  assert_true RGSS::Graphics::TRANSITION_Z > 0xffffff
end

# The VX / VX Ace tile geometry is pure arithmetic, so it is pinned here even
# though drawing needs a display. Every expectation below was taken from a
# differential run against the MIT RPG Maker MV corescript
# (rpgtkoolmv/corescript, js/rpg_core/Tilemap.js), which inherited VX Ace's tile
# system unchanged: all 8300 tile ids x 5 animation frames x the table flag
# produce byte-identical geometry. See docs/rpgvx-rgss-api-gap.md.
assert "RGSS::Tilemap.vx_tile_quads decodes plain tiles" do
  # The B/C/D/E pages are sheets 5..8, one 32x32 quad each.
  assert_equal [[5, 32, 0, 0, 0, 32, 32]], RGSS::Tilemap.vx_tile_quads(1)
  assert_equal [[8, 0, 128, 0, 0, 32, 32]], RGSS::Tilemap.vx_tile_quads(800)
  # A5 is sheet 4.
  assert_equal [[4, 0, 0, 0, 0, 32, 32]], RGSS::Tilemap.vx_tile_quads(1536)
  # Nothing draws for an empty tile, an out-of-range id, or the unused
  # 1024..1535 band between the E page and A5.
  assert_equal [], RGSS::Tilemap.vx_tile_quads(0)
  assert_equal [], RGSS::Tilemap.vx_tile_quads(1024)
  assert_equal [], RGSS::Tilemap.vx_tile_quads(8192)
end

assert "RGSS::Tilemap.vx_tile_quads assembles autotiles from four quads" do
  # A1 water (sheet 0), shape 0: four 16x16 quarter-tiles.
  assert_equal [[0, 32, 64, 0, 0, 16, 16], [0, 16, 64, 16, 0, 16, 16],
                [0, 32, 48, 0, 16, 16, 16], [0, 16, 48, 16, 16, 16, 16]],
               RGSS::Tilemap.vx_tile_quads(2048)
  # A2 ground is sheet 1, A3 buildings sheet 2 (16 wall shapes), A4 walls
  # sheet 3.
  assert_equal 1, RGSS::Tilemap.vx_tile_quads(2816)[0][0]
  assert_equal 2, RGSS::Tilemap.vx_tile_quads(4352)[0][0]
  assert_equal 3, RGSS::Tilemap.vx_tile_quads(5888)[0][0]
  # A wall family has only 16 shapes, so a higher shape draws nothing (as in
  # the corescript, whose table lookup simply misses).
  assert_equal [], RGSS::Tilemap.vx_tile_quads(4352 + 20)
end

assert "RGSS::Tilemap.vx_tile_quads animates water and waterfalls" do
  # The water surface cycles 0,1,2,1 over four frames: frames 1 and 3 share a
  # column, and frame 2 is a further 64px along.
  f0 = RGSS::Tilemap.vx_tile_quads(2048, 0)
  f1 = RGSS::Tilemap.vx_tile_quads(2048, 1)
  f2 = RGSS::Tilemap.vx_tile_quads(2048, 2)
  f3 = RGSS::Tilemap.vx_tile_quads(2048, 3)
  assert_equal 32, f0[0][1]
  assert_equal 96, f1[0][1]
  assert_equal 160, f2[0][1]
  assert_equal f1, f3
  # A waterfall (an odd A1 kind) has its own three-frame cycle, stepping down
  # the sheet rather than across it.
  w0 = RGSS::Tilemap.vx_tile_quads(2288, 0)
  w1 = RGSS::Tilemap.vx_tile_quads(2288, 1)
  assert_equal [480, 0], [w0[0][1], w0[0][2]]
  assert_equal [480, 32], [w1[0][1], w1[0][2]]
end

assert "RGSS::Tilemap.vx_tile_quads matches the reference sweep" do
  # A checksum over the *whole* decode — every tile id, both table settings, one
  # full animation cycle (66,400 cases) — so a regression anywhere in it fails
  # here, not just in the representative cases above. The expected value was
  # computed from the differential run described at the top of this section, in
  # which every one of those cases matched the MV corescript byte for byte.
  #
  # The rolling hash stays inside a 32-bit mrb_int on purpose: the modulus keeps
  # the running value under 2**20, so `sum * 31` cannot overflow.
  sum = 0
  [0, 1, 2, 3].each do |frame|
    [false, true].each do |table|
      id = 0
      while id < 8300
        RGSS::Tilemap.vx_tile_quads(id, frame, table).each do |quad|
          quad.each { |v| sum = (sum * 31 + v) % 1048573 }
        end
        sum = (sum * 31 + id) % 1048573
        id += 1
      end
    end
  end
  assert_equal 782438, sum
end

assert "RGSS::Tilemap.vx_tile_quads splits an A2 table tile" do
  # Without the table flag a shape is four quads; with it, a quad whose source
  # row is a table row is replaced by the counter row plus a 16x8 strip of the
  # original drawn over its bottom half — so a counter shows its side.
  plain = RGSS::Tilemap.vx_tile_quads(2820)
  table = RGSS::Tilemap.vx_tile_quads(2820, 0, true)
  assert_equal 4, plain.size
  assert_equal 5, table.size
  assert_equal [1, 16, 48, 16, 16, 16, 16], table[3]
  assert_equal [1, 48, 16, 16, 24, 16, 8], table[4]
end

assert "RGSS::Tilemap.vx_table_leg_quads grows a table tile's leg into the row below" do
  # A table tile's "leg" is separate from the same-cell counter-row splice
  # above: it is a full 16x16 quad (not the splice's 16x8 strip), sourced from
  # that corner's own *unsubstituted* position, and placed at dy = 24 so it
  # spills 8px past the tile's own 32px box into the map row below. Ported
  # from mkxp's TileAtlasVX::readAutotileA2 (see the comment on
  # vx_table_leg_quads in lib.cxx for the derivation).
  #
  # Shape 4 (tile id 2820) only trips the "table row" condition (qsy == 1 or
  # 5) on its bottom-right corner, so it grows one leg, sourced from exactly
  # the same (sx, sy) as the same-cell strip above (48, 16) — confirming the
  # leg and the splice draw from the same corner, just to different places.
  assert_equal [[1, 48, 16, 16, 24, 16, 16]], RGSS::Tilemap.vx_table_leg_quads(2820)

  # Shape 0 (tile id 2816) trips the condition on neither corner: no legs.
  assert_equal [], RGSS::Tilemap.vx_table_leg_quads(2816)

  # Shape 28 (tile id 2844) trips it on both corners: two legs, one per side
  # (dx 0 for the left, 16 for the right).
  assert_equal [[1, 32, 80, 0, 24, 16, 16], [1, 16, 80, 16, 24, 16, 16]],
               RGSS::Tilemap.vx_table_leg_quads(2844)

  # Only A2 ids can be table tiles; anything else grows no leg.
  assert_equal [], RGSS::Tilemap.vx_table_leg_quads(2048)
  assert_equal [], RGSS::Tilemap.vx_table_leg_quads(4352)
end

assert "RGSS::Tilemap.vx_table_leg_quads matches the reference sweep" do
  # A checksum over every A2 id (the only range a table tile can come from),
  # the same rolling-hash shape as vx_tile_quads's own reference-sweep check
  # above, computed from the same mkxp-derived formula described on
  # vx_table_leg_quads in lib.cxx.
  sum = 0
  id = 2816
  while id < 4352
    RGSS::Tilemap.vx_table_leg_quads(id).each do |quad|
      quad.each { |v| sum = (sum * 31 + v) % 1048573 }
    end
    sum = (sum * 31 + id) % 1048573
    id += 1
  end
  assert_equal 359443, sum
end

assert "RGSS::Tilemap API surface" do
  # Tilemap is now native: Tilemap.new builds an lv_canvas the size of the
  # viewport and blits the visible tiles into it, so construction needs a live
  # display the headless test binary lacks. Assert only the method surface here
  # (the tile rendering is exercised by the game runs), matching Sprite/Plane.
  %i[tileset= map_data= ox= oy= z= visible visible= dispose disposed?
     autotiles priorities priorities= flash_data flash_data= update].each do |m|
    assert_true RGSS::Tilemap.method_defined?(m), "Tilemap##{m} missing"
  end
end

# RGSS::Sprite.new needs an initialized display (it references RGSS::_display),
# which the headless mrbtest build does not set up, so the Sprite extended
# properties cannot be exercised here — they are load-verified with the rest of
# mruby-rgss/mrblib and share the exact accessor pattern the Plane test above
# covers (RGSS defaults, nil?-vs-|| for 0/false-meaningful values, read/write).
