#!/usr/bin/env ruby
# encoding: UTF-8
#
# Unit check for the RPG2000 chipset rendering geometry (Game::ChipsetLayout in
# mruby-rpg2k/mrblib/game.rb). Like scripts/rpg2k_logic_check.rb this loads the
# pure-Ruby source under CRuby — the geometry has no RGSS/SDL dependency, so it
# can be verified without the native binary or any real chipset image.
#
# It pins the tile-id -> chipset source-rect mapping: block classification,
# the single-chip blocks C/E/F, and the four 8x8 quarter assembly of the water
# (A/B) and terrain (D) autotiles. This geometry is independently confirmed
# pixel-identical against a genuine RPG_RT.exe under wine (ADR 0021: 0 of
# 307200 differing pixels across three Nepheshel maps -- town, interior and
# open-water -- with chipset layers, autotiles and upper/lower layering all
# landing on RPG_RT's exact pixels). Every quad it produces must land inside
# the fixed 480x256 chipset grid.
#
# Usage: ruby scripts/rpg2k_render_check.rb   (exits non-zero on any failure)

lib = File.expand_path('../mruby-rpg2k/mrblib', __dir__)
load File.join(lib, 'game.rb')

L = Game::ChipsetLayout

$failures = 0
$checks = 0

def check(name)
  $checks += 1
  yield
rescue StandardError => e
  $failures += 1
  warn "  FAIL #{name}: #{e.class}: #{e.message}"
  warn "    #{e.backtrace.first(3).join("\n    ")}"
end

def ok(cond, msg = 'expected truthy'); raise msg unless cond; end
def eq(exp, act, msg = nil)
  return if exp == act
  raise "expected #{exp.inspect}, got #{act.inspect}#{msg ? " (#{msg})" : ''}"
end

# Every quad must be a valid, in-bounds source rect and a valid destination
# offset within the 16x16 tile.
def assert_quads_valid(quads)
  quads.each do |dx, dy, sx, sy, w, h|
    ok [0, 8].include?(dx), "dest x offset #{dx}"
    ok [0, 8].include?(dy), "dest y offset #{dy}"
    ok [8, 16].include?(w), "width #{w}"
    ok [8, 16].include?(h), "height #{h}"
    ok sx >= 0 && sx + w <= L::CHIPSET_W, "src x #{sx}+#{w} out of 480"
    ok sy >= 0 && sy + h <= L::CHIPSET_H, "src y #{sy}+#{h} out of 256"
  end
end

# -- block classification -----------------------------------------------------

check 'absent and out-of-range ids classify as nil' do
  eq nil, L.block(nil)
  eq nil, L.block(-5)
  eq nil, L.block(5000 + 144)   # one past block E
  eq nil, L.block(10000 + 144)  # one past block F
  eq nil, L.block(20000)
end

check 'ids classify into the six blocks' do
  # Id 0 is water set 0's plain chip, NOT an empty tile: the genuine RPG_RT
  # draws deep water for it, and treating it as empty punched black holes in
  # Nepheshel's sea. Only the upper layer uses 0 to mean "no tile", and that
  # layer's caller skips it before asking.
  eq :water,    L.block(0)
  eq :water,    L.block(1)
  eq :water,    L.block(2500)
  eq :animated, L.block(3000)
  eq :animated, L.block(3050)
  eq :terrain,  L.block(4000)
  eq :terrain,  L.block(4599)
  eq :lower,    L.block(5000)
  eq :lower,    L.block(5143)
  eq :upper,    L.block(10000)
  eq :upper,    L.block(10143)
end

# -- absent tile draws nothing ------------------------------------------------

check 'absent / invalid tiles produce no quads' do
  eq [], L.quads(nil)
  eq [], L.quads(5000 + 144)
  eq [], L.quads(10000 + 144)
end

# Tile 0 is the plain chip of water set 0: four quarters out of block B's first
# row pair, exactly like every other borderless, cornerless water tile.
check 'tile 0 draws water set 0' do
  quads = L.quads(0)
  eq 4, quads.size
  assert_quads_valid quads
  eq L.quads(0), L.water_quads(0, 0)
end

# -- single-chip blocks (C, E, F) ---------------------------------------------

check 'block E lower tiles map to a single 16x16 chip' do
  q = L.quads(5000)
  eq 1, q.size
  eq [0, 0, 12 * 16, 0, 16, 16], q.first  # id 0 -> col 12, row 0
  assert_quads_valid q

  # id 6 -> second row of the first 6-wide column
  eq [0, 0, 12 * 16, 1 * 16, 16, 16], L.quads(5006).first
  # id 96 -> start of the second column (col 18, row 0)
  eq [0, 0, 18 * 16, 0, 16, 16], L.quads(5000 + 96).first
  assert_quads_valid L.quads(5143)
end

check 'block F upper tiles map to a single 16x16 chip in the right half' do
  # id 0 -> col 18, row 8
  eq [0, 0, 18 * 16, 8 * 16, 16, 16], L.quads(10000).first
  # id 48 -> second column group (col 24, row 0)
  eq [0, 0, 24 * 16, 0, 16, 16], L.quads(10000 + 48).first
  assert_quads_valid L.quads(10000)
  assert_quads_valid L.quads(10143)
end

check 'block C animated tiles pick their row from the animation frame' do
  # id 3000 -> col 3, row 4 + frame
  eq [0, 0, 3 * 16, 4 * 16, 16, 16], L.quads(3000, 0, 0).first
  eq [0, 0, 3 * 16, 7 * 16, 16, 16], L.quads(3000, 0, 3).first
  # id 3050 -> col 4
  eq [0, 0, 4 * 16, 4 * 16, 16, 16], L.quads(3050, 0, 0).first
  assert_quads_valid L.quads(3000, 0, 2)
end

# -- autotiles (A/B water, D terrain) -----------------------------------------

check 'water autotiles assemble four in-bounds 8x8 quarters' do
  # Sweep every water set / border / corner combination.
  (0..2).each do |set|
    (0...16).each do |b|
      (0...L::BLOCK_A_SUBTILES.size).each do |a|
        id = set * 1000 + b * 50 + a
        next if id.zero?
        (0..2).each do |anim|
          q = L.quads(id, anim, 0)
          eq 4, q.size, "id #{id} anim #{anim}"
          # The four quarters tile the destination (TL, TR, BL, BR).
          eq [[0, 0], [8, 0], [0, 8], [8, 8]], q.map { |dx, dy, *| [dx, dy] }
          assert_quads_valid q
        end
      end
    end
  end
end

check 'water quarters come from the correct A/B chipset rows' do
  # a_subtile 46 is "all four corners" -> every quarter is block-A row 0.
  q = L.quads(46, 0, 0) # set 0, b_subtile 0, a_subtile 46
  q.each { |_, _, _, sy, _, _| eq 0, sy / 16, 'block-A row 0 expected' }
  # b_subtile 15 (all borders), a_subtile 0 -> every quarter is block-B (rows 4..7).
  L.quads(15 * 50, 0, 0).each do |_, _, _, sy, _, _|
    ok (4..7).include?(sy / 16), "block-B row, got #{sy / 16}"
  end
end

check 'water set 1 uses the second block-A column trio (anim + 3)' do
  # set 1, a_subtile 46 (all block A). Column = anim + 3.
  L.quads(1000 + 46, 1, 0).each do |_, _, sx, _, _, _|
    ok [4, 5].include?(sx / 16), "expected col 4/5 for set1 anim1, got #{sx / 16}"
  end
end

check 'terrain autotiles assemble four in-bounds 8x8 quarters' do
  (0...12).each do |blk|
    (0...50).each do |sub|
      id = 4000 + blk * 50 + sub
      q = L.quads(id)
      eq 4, q.size, "id #{id}"
      eq [[0, 0], [8, 0], [0, 8], [8, 8]], q.map { |dx, dy, *| [dx, dy] }
      assert_quads_valid q
    end
  end
end

check 'terrain block placement follows the two-column D layout' do
  # block 0 -> first column, lower region (base col 0, base row 8).
  # subtile 46 (all-solid-ish) uses offset [1,2] for every quarter in the port.
  q0 = L.quads(4000 + 0 * 50 + 47) # subtile 47 -> [1,2] all quarters
  q0.each do |_, _, sx, sy, _, _|
    eq (0 + 1), sx / 16, 'block0 col'
    eq (8 + 2), sy / 16, 'block0 row'
  end
  # block 4 -> second column, top region (base col 6, base row 0).
  q4 = L.quads(4000 + 4 * 50 + 47)
  q4.each do |_, _, sx, sy, _, _|
    eq (6 + 1), sx / 16, 'block4 col'
    eq (0 + 2), sy / 16, 'block4 row'
  end
end

# -- animation helpers --------------------------------------------------------

check 'anim_ab: slow chipset advances every 24 frames, type 0 walks 0,1,2,1' do
  seq = (0...4).map { |k| L.anim_ab(k * 24, 0, 0) }
  eq [0, 1, 2, 1], seq
  # Fast chipset (speed != 0) advances every 12 frames.
  eq 1, L.anim_ab(12, 0, 1)
end

check 'anim_ab: type 1 cycles 0,1,2' do
  seq = (0...3).map { |k| L.anim_ab(k * 24, 1, 0) }
  eq [0, 1, 2], seq
  eq 0, L.anim_ab(3 * 24, 1, 0)
end

check 'anim_c cycles 0..3 every 6 frames' do
  eq [0, 1, 2, 3, 0], (0..4).map { |k| L.anim_c(k * 6) }
end

# -- event tile substitution (ported from a reference implementation, not
#    independently confirmed against genuine RPG_RT under wine) -------------

check 'event_tile_rect maps the three tile palettes to the chipset lower-right' do
  # tile 0 and out-of-range ids fall back to the first (empty) tile.
  eq [288, 128, 16, 16], L.event_tile_rect(0)
  eq [288, 128, 16, 16], L.event_tile_rect(144)
  eq [288, 128, 16, 16], L.event_tile_rect(-1)
  # Palette 1 (ids 1..47) starts at (288,128) and runs 6 wide.
  eq [304, 128, 16, 16], L.event_tile_rect(1)
  eq [368, 240, 16, 16], L.event_tile_rect(47)
  # Palette 2 (ids 48..95) starts at (384,0).
  eq [384, 0, 16, 16], L.event_tile_rect(48)
  eq [464, 112, 16, 16], L.event_tile_rect(95)
  # Palette 3 (ids 96..143) starts at (384,128). idx 97 is Nepheshel's ground
  # decoration event.
  eq [384, 128, 16, 16], L.event_tile_rect(96)
  eq [400, 128, 16, 16], L.event_tile_rect(97)
  eq [464, 240, 16, 16], L.event_tile_rect(143)
end

check 'every event tile id lands inside the 480x256 chipset' do
  (0..160).each do |t|
    sx, sy, w, h = L.event_tile_rect(t)
    ok sx >= 0 && sx + w <= L::CHIPSET_W, "tile #{t} x #{sx}+#{w}"
    ok sy >= 0 && sy + h <= L::CHIPSET_H, "tile #{t} y #{sy}+#{h}"
  end
end

# -- event graphic frame selection (Game::EventGraphic) -----------------------

EG = Game::EventGraphic

check 'LCF page facing converts to the numpad convention' do
  eq 8, EG.numpad_direction(0) # up
  eq 6, EG.numpad_direction(1) # right
  eq 2, EG.numpad_direction(2) # down
  eq 4, EG.numpad_direction(3) # left
  eq 2, EG.numpad_direction(nil) # unknown -> down
end

check 'pattern_column walks middle,right,middle,left' do
  eq [1, 2, 1, 0], (0..3).map { |p| EG.pattern_column(p) }
  eq 1, EG.pattern_column(4) # wraps
end

check 'a fixed-graphic event never animates, but still draws its live facing' do
  # anim type 4: always the page pattern regardless of phase / motion -- but
  # the row drawn is char_dir, not base_dir, so an explicit Face Direction
  # move-route command can still turn the sprite (Character#fixed_facing
  # gates movement-driven turning only, not #face!'s explicit one).
  eq [8, 1], EG.frame(EG::FIXED_GRAPHIC, 2, 1, 8, 3, true)
  eq [4, 0], EG.frame(EG::FIXED_GRAPHIC, 6, 0, 4, 1, false)
end

check 'a spinning event derives facing from the phase but keeps its own ' \
      'pattern column' do
  # base_pattern (2) is carried through unchanged on every phase -- a graphic
  # that repurposes the 3 columns for unrelated frames (Nepheshel's Crystal
  # Gate save point: column 0 lit, column 2 unlit) must keep showing its own
  # column while only the row (facing) cycles, not fall back to a fixed
  # "standing" column that happens to belong to a different picture.
  eq [2, 2], EG.frame(EG::SPIN, 8, 2, 4, 0, false)
  eq [4, 2], EG.frame(EG::SPIN, 8, 2, 4, 1, false)
  eq [8, 2], EG.frame(EG::SPIN, 8, 2, 4, 2, false)
  eq [6, 2], EG.frame(EG::SPIN, 8, 2, 4, 3, false)
end

check 'ordinary events walk while moving and rest on the page pose when idle' do
  # non-continuous (0): faces its movement, walks only while stepping.
  eq [6, 2], EG.frame(EG::NON_CONTINUOUS, 2, 1, 6, 1, true)  # moving -> walk col
  eq [6, 1], EG.frame(EG::NON_CONTINUOUS, 2, 1, 6, 1, false) # idle -> page pattern
  # fixed-direction non-continuous (2): walk animation still gated on
  # `moving`, but the row drawn is char_dir (pinned at base_dir by movement,
  # turned only by an explicit Face Direction command), not base_dir itself.
  eq [6, 2], EG.frame(EG::FIXED_NON_CONTINUOUS, 2, 1, 6, 1, true)
  eq [6, 1], EG.frame(EG::FIXED_NON_CONTINUOUS, 2, 1, 6, 1, false)
end

check 'continuous events animate even while standing still' do
  # continuous (1): faces movement, always cycles regardless of `moving`.
  eq [6, 2], EG.frame(EG::CONTINUOUS, 2, 1, 6, 1, false)
  # fixed continuous (3): always cycles, drawn at char_dir (see above).
  eq [6, 2], EG.frame(EG::FIXED_CONTINUOUS, 2, 1, 6, 1, false)
end

check 'animation-type predicates classify the six types' do
  ok EG.fixed_direction?(EG::FIXED_NON_CONTINUOUS)
  ok EG.fixed_direction?(EG::FIXED_GRAPHIC)
  ok !EG.fixed_direction?(EG::NON_CONTINUOUS)
  ok EG.continuous?(EG::CONTINUOUS)
  ok EG.continuous?(EG::SPIN)
  ok !EG.continuous?(EG::NON_CONTINUOUS)
  ok EG.animated?(EG::NON_CONTINUOUS)
  ok !EG.animated?(EG::FIXED_GRAPHIC)
end

# -- parallax background geometry (Game::Parallax) ----------------------------

PX = Game::Parallax

check 'a non-looping panorama no larger than the screen stays fixed' do
  # The common Nepheshel full-screen backdrop: 640x480 image, any camera -> 0.
  eq 0, PX.axis_offset(false, false, 0, 0, 0,   640, 1280, 640)
  eq 0, PX.axis_offset(false, false, 0, 0, 320, 640,  1280, 640)
  eq 0, PX.axis_offset(false, false, 0, 0, 999, 480,  2000, 480) # y axis
end

check 'a non-looping panorama wider than the screen pans across its excess' do
  # img 1280, screen 640, map 1280 -> camera 0..640 reveals the 640px excess.
  eq 0,    PX.axis_offset(false, false, 0, 0, 0,   640, 1280, 1280)
  eq(-320, PX.axis_offset(false, false, 0, 0, 320, 640, 1280, 1280))
  eq(-640, PX.axis_offset(false, false, 0, 0, 640, 640, 1280, 1280))
  # Camera clamps, so past the edge it holds at the far offset.
  eq(-640, PX.axis_offset(false, false, 0, 0, 9999, 640, 1280, 1280))
end

check 'a non-looping panorama wider than the map\'s own excess pans by the ' \
      'map\'s excess, not the image\'s' do
  # Ported from a reference implementation's parallax reset-position logic,
  # NOT independently confirmed against genuine RPG_RT under wine: the span
  # panned across is min(map excess, image excess), not always the image's
  # own full excess. A small map (800px,
  # 160px of scroll room) with a much wider panorama (2000px, 1360px of its
  # own excess) must stop at the map's own 160px scroll limit -- the image
  # never fully reveals its own far edge, since there is nowhere left on the
  # map for the camera to go looking for it.
  eq 0,    PX.axis_offset(false, false, 0, 0, 0,   640, 800, 2000)
  eq(-80,  PX.axis_offset(false, false, 0, 0, 80,  640, 800, 2000)) # halfway
  eq(-160, PX.axis_offset(false, false, 0, 0, 160, 640, 800, 2000)) # map's own max
  # Past the map's own scroll range, the camera itself clamps -- same 160,
  # not the image's 1360px excess a missing min() would have reported.
  eq(-160, PX.axis_offset(false, false, 0, 0, 9999, 640, 800, 2000))
end

check 'a looping panorama scrolls at half the camera rate and wraps' do
  eq 0,   PX.axis_offset(true, false, 0, 0, 0,   640, 4096, 256)
  eq(-50, PX.axis_offset(true, false, 0, 0, 100, 640, 4096, 256)) # half of 100
  eq 0,   PX.axis_offset(true, false, 0, 0, 512, 640, 4096, 256)  # 256 -> wraps to 0
  eq(-44, PX.axis_offset(true, false, 0, 0, 600, 640, 4096, 256)) # 300 % 256 = 44
end

check 'autoscroll pixel delta follows the speed field (ported from a ' \
      'reference implementation, not independently confirmed against ' \
      'genuine RPG_RT under wine)' do
  eq 0, PX.autoscroll_px(0, 1000)
  eq 0, PX.autoscroll_px(nil, 1000)
  eq(-16,  PX.autoscroll_px(4, 32))   # -(1<<4)=-16 per 32 frames
  eq(-256, PX.autoscroll_px(8, 32))   # -(1<<8)=-256
  eq 4,    PX.autoscroll_px(-2, 32)   # +(1<<2)=4
end

check 'a looping panorama with autoscroll drifts over time and stays in range' do
  img = 256
  (0..600).step(30).each do |frame|
    off = PX.axis_offset(true, true, 4, frame, 0, 640, 4096, img)
    ok off <= 0 && off > -img, "offset #{off} out of (-#{img}, 0]"
  end
end

check 'a zero-size or absent panorama axis offsets to 0' do
  eq 0, PX.axis_offset(true, false, 0, 0, 100, 640, 4096, 0)
  eq 0, PX.axis_offset(false, false, 0, 0, 100, 640, 4096, nil)
end

# -- message text palette geometry (Game::MessagePalette) ---------------------

MP = Game::MessagePalette

check 'message palette swatches form a 10x2 grid from y=48' do
  eq [0, 48],   MP.cell_origin(0)
  eq [16, 48],  MP.cell_origin(1)
  eq [144, 48], MP.cell_origin(9)   # last of the top row
  eq [0, 64],   MP.cell_origin(10)  # second row
  eq [144, 64], MP.cell_origin(19)  # last swatch
end

check 'every swatch cell lands inside the 160x80 System image' do
  seen = {}
  (0...MP::COUNT).each do |i|
    x, y = MP.cell_origin(i)
    ok x >= 0 && x + MP::CELL <= 160, "cell x #{x} for #{i}"
    ok y >= 48 && y + MP::CELL <= 80, "cell y #{y} for #{i}"
    ok !seen[[x, y]], "cell origin #{[x, y]} reused"
    seen[[x, y]] = true
  end
  eq 20, seen.size, 'twenty distinct swatch cells'
end

check 'the shadow block sits beside the system-background block' do
  eq [16, 32], MP.shadow_origin
  eq 1, MP::SHADOW_OFFSET
  # It must not overlap the colour swatches (which start at y = 48).
  ok MP.shadow_origin[1] + MP::CELL <= MP::Y_OFFSET
end

check 'MessagePalette.valid? bounds the colour index' do
  ok MP.valid?(0)
  ok MP.valid?(19)
  ok !MP.valid?(20)
  ok !MP.valid?(-1)
  ok !MP.valid?(nil)
end

# -- selection cursor geometry (Game::WindowCursor) ---------------------------

WC = Game::WindowCursor

check 'the cursor overhangs the content area horizontally but not vertically' do
  # Nepheshel's title window: contents 48x48 at border 8, three 16px rows.
  # Measured off a genuine RPG_RT frame: the cursor is 56x16 at (4, 8) within
  # the window, i.e. four pixels wider on each side and exactly one row tall.
  eq [4, 8, 56, 16], WC.dest_rect(0, 0, 48, 16, 8)
  # Row 1 and row 2 simply step down by the row height.
  eq [4, 24, 56, 16], WC.dest_rect(0, 16, 48, 16, 8)
  eq [4, 40, 56, 16], WC.dest_rect(0, 32, 48, 16, 8)
end

check 'the cursor block is the 32x32 patch at (64, 0) of the System image' do
  eq 32, WC::SIZE
  eq 8, WC::CORNER
  eq 64, WC::FRAME1_X
  eq 96, WC::FRAME2_X
  eq 0, WC::FRAME_Y
  # Both frames stay inside the 160x80 System image and clear the swatch rows.
  ok WC::FRAME2_X + WC::SIZE <= 160
  ok WC::FRAME_Y + WC::SIZE <= MP::Y_OFFSET
end

# -- bush depth (Game::CharSet.bush_pixels / .bush_opacity) -------------------

CS = Game::CharSet

# RPG_RT stores the depth as a divisor's complement: `4 - depth`, and a divisor
# above 3 means no effect, so only 1..3 sink anything. On the 32px charset frame
# that is exactly the thirds and halves Nepheshel's terrain names promise.
check 'bush depth converts to a pixel split the way RPG_RT does' do
  eq 0, CS.bush_pixels(0), 'ordinary ground sinks nothing'
  eq 10, CS.bush_pixels(1), '下半身3/1消去 — the lower third of 32'
  eq 16, CS.bush_pixels(2), '下半身2/1消去 — the lower half'
  eq 32, CS.bush_pixels(3), '全身半透明 — the whole frame'
end

check 'a depth outside 1..3 sinks nothing' do
  eq 0, CS.bush_pixels(nil)
  eq 0, CS.bush_pixels(-1)
  eq 0, CS.bush_pixels(4), 'divisor 0 would be a division by zero, not a sink'
  eq 0, CS.bush_pixels(9)
end

check 'the split scales to the frame it is given' do
  # A tile-graphic event is one 16px tile tall, not a 32px charset frame.
  eq [0, 5, 8, 16], (0..3).map { |d| CS.bush_pixels(d, 16) }
end

# RPG_RT's opacity_bottom default: half the top opacity, rounded up. Halving
# rather than fixing it at 128 is what keeps an already-translucent event
# fainter still when it wades in.
check 'the sunken rows draw at half the opacity, rounded up' do
  eq 128, CS.bush_opacity(255)
  eq 128, CS.bush_opacity
  eq 64, CS.bush_opacity(128), 'a translucent event halves again'
  eq 1, CS.bush_opacity(1)
  eq 0, CS.bush_opacity(0)
end

if $failures.zero?
  puts "rpg2k render check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k render check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
