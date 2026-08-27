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
# With no GAME_DIR, uses data/Nepheshel206beta/Nepheshel206Nbeta (see
# scripts/download-nepheshel.bash). With no MAP_ID, checks a small sample of
# maps spread across the project. Exits non-zero on any failure.

require 'tmpdir'
require 'open3'

ROOT = File.expand_path('..', __dir__)
EXPORTER = File.join(ROOT, 'scripts/export_nano7_map.rb')

MAP_MAX_W = 128
MAP_MAX_H = 128
MAX_TILES = 256
UPPER_NONE = 0xFFFF
VALID_PASSABLE_BITS = 0x0F # down|left|right|up -- see DIR_BITS in the exporter

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

def read_map_bin(path)
  bytes = File.binread(path)
  magic = bytes[0, 4]
  version, _pad = bytes[4, 2].unpack('CC')
  width, height, start_x, start_y, tile_count, _pad2 = bytes[6, 12].unpack('v6')
  off = 18
  cells = width * height
  lower = bytes[off, cells * 2].unpack('v*'); off += cells * 2
  upper = bytes[off, cells * 2].unpack('v*'); off += cells * 2
  passable = bytes[off, cells].unpack('C*'); off += cells
  ok(off == bytes.bytesize, "map.bin has #{bytes.bytesize - off} trailing bytes")
  {
    magic: magic, version: version, width: width, height: height,
    start_x: start_x, start_y: start_y, tile_count: tile_count,
    lower: lower, upper: upper, passable: passable
  }
end

def check_export(game_dir, map_id)
  Dir.mktmpdir('n7export') do |out_dir|
    stdout, stderr, status = Open3.capture3('ruby', EXPORTER, game_dir, map_id.to_s, out_dir)
    check("#{game_dir} map #{map_id}: exporter exits 0") { ok status.success?, "exit #{status.exitstatus}: #{stderr}" }
    next unless status.success?
    puts "  #{stdout.strip}"

    map = read_map_bin(File.join(out_dir, 'map.bin'))
    tiles_bytes = File.binread(File.join(out_dir, 'tiles.bin'))

    check("map #{map_id}: magic") { ok map[:magic] == 'N7WM', map[:magic].inspect }
    check("map #{map_id}: version") { ok map[:version] == 1, map[:version] }
    check("map #{map_id}: dimensions in bounds") do
      ok map[:width].positive? && map[:height].positive?, 'non-positive dimensions'
      ok map[:width] <= MAP_MAX_W && map[:height] <= MAP_MAX_H, "#{map[:width]}x#{map[:height]}"
    end
    check("map #{map_id}: tile_count in bounds") { ok map[:tile_count] <= MAX_TILES, map[:tile_count] }
    check("map #{map_id}: start position inside map") do
      ok map[:start_x] >= 0 && map[:start_x] < map[:width], "start_x #{map[:start_x]}"
      ok map[:start_y] >= 0 && map[:start_y] < map[:height], "start_y #{map[:start_y]}"
    end
    check("map #{map_id}: tiles.bin size matches tile_count") do
      expected = map[:tile_count] * 16 * 16 * 4
      ok tiles_bytes.bytesize == expected, "#{tiles_bytes.bytesize} != #{expected}"
    end
    check("map #{map_id}: every lower-layer index resolves into the atlas") do
      bad = map[:lower].reject { |i| i < map[:tile_count] }
      ok bad.empty?, "#{bad.size} out-of-range indices, e.g. #{bad.first}"
    end
    check("map #{map_id}: every upper-layer index resolves or is NONE") do
      bad = map[:upper].reject { |i| i == UPPER_NONE || i < map[:tile_count] }
      ok bad.empty?, "#{bad.size} out-of-range indices, e.g. #{bad.first}"
    end
    check("map #{map_id}: passable bytes use only the four direction bits") do
      bad = map[:passable].reject { |b| (b & ~VALID_PASSABLE_BITS).zero? }
      ok bad.empty?, "#{bad.size} bytes with stray bits, e.g. 0x%02x" % (bad.first || 0)
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

map_ids.each { |id| check_export(game_dir, id) }

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
