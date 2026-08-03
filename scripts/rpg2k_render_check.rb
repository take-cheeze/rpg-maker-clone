#!/usr/bin/env ruby
# encoding: UTF-8
#
# Unit check for the RPG2000 chipset rendering geometry (Game::ChipsetLayout in
# mruby-rpg2k/mrblib/game.rb). Like scripts/rpg2k_logic_check.rb this loads the
# pure-Ruby source under CRuby — the geometry has no RGSS/SDL dependency, so it
# can be verified without the native binary or any real chipset image.
#
# It pins the tile-id -> chipset source-rect mapping ported from EasyRPG Player's
# TilemapLayer: block classification, the single-chip blocks C/E/F, and the four
# 8x8 quarter assembly of the water (A/B) and terrain (D) autotiles. Every quad
# it produces must land inside the fixed 480x256 chipset grid.
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

check 'empty and out-of-range ids classify as nil' do
  eq nil, L.block(0)
  eq nil, L.block(nil)
  eq nil, L.block(-5)
  eq nil, L.block(5000 + 144)   # one past block E
  eq nil, L.block(10000 + 144)  # one past block F
  eq nil, L.block(20000)
end

check 'ids classify into the six blocks' do
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

# -- empty tile draws nothing -------------------------------------------------

check 'empty / invalid tiles produce no quads' do
  eq [], L.quads(0)
  eq [], L.quads(nil)
  eq [], L.quads(5000 + 144)
  eq [], L.quads(10000 + 144)
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

if $failures.zero?
  puts "rpg2k render check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k render check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
