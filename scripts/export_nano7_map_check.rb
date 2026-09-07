#!/usr/bin/env ruby
# encoding: UTF-8
#
# Smoke-test scripts/export_nano7_map.rb against a real RPG2000 test-bed
# project: runs the exporter, then re-parses map.bin/tiles.bin as plain
# binary (independent of the exporter's own writer code) and checks the
# invariants the on-device reader (app/nano7/rpg2k_walk/rpg2k_walk.c) relies
# on -- so a mismatch between the exporter's format and the C reader's
# expectations fails here instead of on real hardware.
#
# Usage:
#   ruby scripts/export_nano7_map_check.rb [GAME_DIR [MAP_ID ...]]
#
# Every sampled map is exported twice: once for the iPod nano 7G and once for
# the Wio Terminal, whose smaller buffers (app/wio/src/walk_main.cxx) it must
# either fit or be refused by, never silently exceed.
# With no GAME_DIR, uses data/Nepheshel206beta/Nepheshel206Nbeta (see
# scripts/download-nepheshel.bash). With no MAP_ID, checks a small sample of
# maps spread across the project. Exits non-zero on any failure.

require 'tmpdir'
require 'open3'

ROOT = File.expand_path('..', __dir__)
EXPORTER = File.join(ROOT, 'scripts/export_nano7_map.rb')

# Mirrors TARGETS in the exporter, which mirrors each firmware's buffers.
TARGETS = {
  'nano7' => { max_w: 128, max_h: 128, max_tiles: 255 },
  'wio' => { max_w: 128, max_h: 128, max_tiles: 192 }
}.freeze
MAP_MAX_W = TARGETS['nano7'][:max_w]
MAP_MAX_H = TARGETS['nano7'][:max_h]
MAX_TILES = TARGETS['nano7'][:max_tiles]
MAP_VERSION = 4
UPPER_NONE = 0xFF
VALID_PASSABLE_BITS = 0x0F # down|left|right|up -- see DIR_BITS in the exporter
TILE_BYTES = 16 * 16       # one palette index per pixel
OPAQUE_BIT = 0x8000
TRANSPARENT_INDEX = 0
MAX_PALETTE = 256

$failures = 0
$checks = 0

def check(name)
  $checks += 1
  yield
rescue StandardError => e
  $failures += 1
  warn "  FAIL #{name}: #{e.class}: #{e.message}"
end

def ok(cond, msg)
  raise msg unless cond
end

# The colour key an RPG Maker chipset keys on: palette entry 0 of the PNG,
# packed the way the exporter packs pixels. Reading it here -- from the very
# file the exporter reported using -- is what makes the "no opaque atlas pixel
# is the colour key" check below a real regression test for the exporter
# loading the chipset without RPG Maker's transparency flag, which baked that
# colour into every transparent pixel (docs/adr/0061's known bug).
def png_palette0(path)
  bytes = File.binread(path)
  return nil unless bytes[0, 8] == "\x89PNG\r\n\x1a\n".b

  off = 8
  while off + 8 <= bytes.bytesize
    len = bytes[off, 4].unpack1('N')
    type = bytes[off + 4, 4]
    return bytes[off + 8, 3].unpack('C3') if type == 'PLTE' && len >= 3
    break if type == 'IEND'
    off += 12 + len
  end
  nil
end

def to5(v)
  (v * 31 + 127) / 255
end

def pack1555(r, g, b)
  OPAQUE_BIT | (to5(r) << 10) | (to5(g) << 5) | to5(b)
end

def read_map_bin(path)
  bytes = File.binread(path)
  magic = bytes[0, 4]
  version, _pad = bytes[4, 2].unpack('CC')
  width, height, start_x, start_y, tile_count, backdrop = bytes[6, 12].unpack('v6')
  palette_count = bytes[18, 2].unpack1('v')
  palette = bytes[20, palette_count * 2].unpack('v*')
  off = 20 + palette_count * 2
  cells = width * height
  lower = bytes[off, cells].unpack('C*'); off += cells
  upper = bytes[off, cells].unpack('C*'); off += cells
  # Passability is a nibble per cell, the even cell in the low half.
  packed = bytes[off, (cells + 1) / 2].unpack('C*'); off += (cells + 1) / 2
  passable = (0...cells).map { |i| i.even? ? (packed[i / 2] & 0x0F) : (packed[i / 2] >> 4) }
  ok(off == bytes.bytesize, "map.bin has #{bytes.bytesize - off} trailing bytes")
  {
    magic: magic, version: version, width: width, height: height,
    start_x: start_x, start_y: start_y, tile_count: tile_count,
    backdrop: backdrop, palette: palette, lower: lower, upper: upper,
    passable: passable
  }
end

def check_export(game_dir, map_id)
  Dir.mktmpdir('n7export') do |out_dir|
    stdout, stderr, status = Open3.capture3('ruby', EXPORTER, game_dir, map_id.to_s, out_dir)
    # The chipset name comes from the game's own (CP932-decoded) data, so the
    # exporter's line is UTF-8 whatever the locale this check runs under says.
    stdout = stdout.dup.force_encoding('UTF-8')
    check("#{game_dir} map #{map_id}: exporter exits 0") { ok status.success?, "exit #{status.exitstatus}: #{stderr}" }
    next unless status.success?
    puts "  #{stdout.strip}"

    map = read_map_bin(File.join(out_dir, 'map.bin'))
    tiles_bytes = File.binread(File.join(out_dir, 'tiles.bin'))
    tiles = tiles_bytes.unpack('C*')
    chipset_path = stdout[/ from (.+)$/, 1]

    check("map #{map_id}: magic") { ok map[:magic] == 'N7WM', map[:magic].inspect }
    check("map #{map_id}: version") { ok map[:version] == MAP_VERSION, map[:version] }
    check("map #{map_id}: dimensions in bounds") do
      ok map[:width].positive? && map[:height].positive?, 'non-positive dimensions'
      ok map[:width] <= MAP_MAX_W && map[:height] <= MAP_MAX_H, "#{map[:width]}x#{map[:height]}"
    end
    check("map #{map_id}: tile_count in bounds") do
      ok map[:tile_count] <= MAX_TILES, map[:tile_count]
      # An atlas index is a byte on-device, with 0xFF reserved for "no upper
      # tile", so 255 entries is a hard ceiling whatever the target allows.
      ok map[:tile_count] <= UPPER_NONE, "#{map[:tile_count]} entries cannot be indexed by a byte"
    end
    check("map #{map_id}: start position inside map") do
      ok map[:start_x] >= 0 && map[:start_x] < map[:width], "start_x #{map[:start_x]}"
      ok map[:start_y] >= 0 && map[:start_y] < map[:height], "start_y #{map[:start_y]}"
    end
    check("map #{map_id}: tiles.bin size matches tile_count") do
      expected = map[:tile_count] * TILE_BYTES
      ok tiles_bytes.bytesize == expected, "#{tiles_bytes.bytesize} != #{expected}"
    end
    check("map #{map_id}: the palette fits a one-byte index") do
      ok map[:palette].size.between?(1, MAX_PALETTE), "#{map[:palette].size} entries"
      ok map[:palette][TRANSPARENT_INDEX].zero?,
         "entry 0 is 0x%04x, not the transparent slot" % map[:palette][TRANSPARENT_INDEX]
    end
    check("map #{map_id}: every palette colour past 0 is opaque and distinct") do
      colours = map[:palette].drop(1)
      bad = colours.reject { |c| (c & OPAQUE_BIT) != 0 }
      ok bad.empty?, "#{bad.size} non-opaque entries, e.g. 0x%04x" % (bad.first || 0)
      ok colours.uniq.size == colours.size, "#{colours.size - colours.uniq.size} duplicate colours"
    end
    check("map #{map_id}: every pixel indexes into the palette") do
      bad = tiles.reject { |i| i < map[:palette].size }
      ok bad.empty?, "#{bad.size} out-of-range indices, e.g. #{bad.first}"
    end
    # The bug this guards: with the chipset loaded without RPG Maker's
    # "palette index 0 is transparent" flag, every keyed pixel exported as an
    # opaque block of that palette colour (magenta on Nepheshel's chipsets).
    # The colour key cannot be a palette entry now, so one check covers every
    # pixel that could carry it.
    check("map #{map_id}: the chipset's colour key is not a palette colour") do
      ok chipset_path, 'exporter did not report a chipset path'
      ok File.file?(chipset_path), "reported chipset missing: #{chipset_path}"
      pal0 = png_palette0(chipset_path)
      ok pal0, "no PLTE in #{chipset_path}"
      key = pack1555(*pal0)
      ok !map[:palette].include?(key),
         "the colour key 0x%04x (#{pal0.inspect}) is in the palette" % key
    end
    check("map #{map_id}: atlas entries are deduplicated") do
      slots = (0...map[:tile_count]).map { |i| tiles[i * TILE_BYTES, TILE_BYTES] }
      ok slots.uniq.size == slots.size, "#{slots.size - slots.uniq.size} duplicate atlas entries"
    end
    check("map #{map_id}: backdrop is opaque or absent") do
      bd = map[:backdrop]
      ok bd.zero? || (bd & OPAQUE_BIT) != 0, "0x%04x" % bd
    end
    check("map #{map_id}: every lower-layer index resolves into the atlas") do
      bad = map[:lower].reject { |i| i < map[:tile_count] }
      ok bad.empty?, "#{bad.size} out-of-range indices, e.g. #{bad.first}"
    end
    check("map #{map_id}: every upper-layer index resolves or is NONE") do
      bad = map[:upper].reject { |i| i == UPPER_NONE || i < map[:tile_count] }
      ok bad.empty?, "#{bad.size} out-of-range indices, e.g. #{bad.first}"
    end
    check("map #{map_id}: passable nibbles use only the four direction bits") do
      bad = map[:passable].reject { |b| (b & ~VALID_PASSABLE_BITS).zero? }
      ok bad.empty?, "#{bad.size} nibbles with stray bits, e.g. 0x%02x" % (bad.first || 0)
    end
  end
end

# The same export for the smaller device: a map that fits its buffers must
# come out inside them, and one that does not must be refused with a message
# naming the cap -- never truncated into something the firmware would load and
# draw wrong.
def check_wio_target(game_dir, map_id)
  caps = TARGETS['wio']
  Dir.mktmpdir('n7export') do |out_dir|
    stdout, stderr, status =
      Open3.capture3('ruby', EXPORTER, '--target', 'wio', game_dir, map_id.to_s, out_dir)
    stdout = stdout.dup.force_encoding('UTF-8')
    stderr = stderr.dup.force_encoding('UTF-8')

    if status.success?
      map = read_map_bin(File.join(out_dir, 'map.bin'))
      check("map #{map_id} (wio): export fits the smaller device") do
        ok map[:width] <= caps[:max_w] && map[:height] <= caps[:max_h],
           "#{map[:width]}x#{map[:height]} past #{caps[:max_w]}x#{caps[:max_h]}"
        ok map[:tile_count] <= caps[:max_tiles], "#{map[:tile_count]} tiles"
      end
      check("map #{map_id} (wio): output names the target") do
        ok stdout.include?('target wio'), stdout
      end
    else
      check("map #{map_id} (wio): refusal names the cap it hit") do
        ok stderr =~ /exceeds on-device bounds|exceeding the on-device cap/, stderr
      end
    end
  end
end

def discover_default_maps(game_dir, sample = 5)
  ids = Dir[File.join(game_dir, 'Map*.lmu')].map { |f| File.basename(f)[/\d+/].to_i }.sort
  return ids if ids.size <= sample
  step = ids.size / sample
  ids.each_slice([step, 1].max).map(&:first).first(sample)
end

game_dir = ARGV[0] || File.join(ROOT, 'data/Nepheshel206beta/Nepheshel206Nbeta')
unless Dir.exist?(game_dir)
  warn "no test-bed game at #{game_dir} -- run scripts/download-nepheshel.bash first, or pass a GAME_DIR"
  exit 0
end

map_ids = ARGV.drop(1).map(&:to_i)
map_ids = discover_default_maps(game_dir) if map_ids.empty?

map_ids.each do |id|
  check_export(game_dir, id)
  check_wio_target(game_dir, id)
end

# An oversized map (bigger than MAP_MAX_W/H) must be refused cleanly with a
# non-zero exit and a clear message, not crash or silently truncate. Only
# run this if the default test-bed game actually has one -- a GAME_DIR the
# caller points at a different, all-small-maps project should not fail here.
if game_dir == File.join(ROOT, 'data/Nepheshel206beta/Nepheshel206Nbeta')
  check('oversized map is refused, not truncated') do
    _stdout, stderr, status = Open3.capture3('ruby', EXPORTER, game_dir, '192', Dir.mktmpdir('n7export'))
    ok !status.success?, 'exporter accepted a 230x50 map past the 128x128 cap'
    ok stderr.include?('exceeds on-device bounds'), "unexpected message: #{stderr}"
  end
end

puts "#{$checks} checks, #{$failures} failures"
exit($failures.zero? ? 0 : 1)
