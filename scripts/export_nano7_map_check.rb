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

# For check_hero_geometry only: the same Game::CharSet.frame_rect geometry
# and colour-keyed PNG decoder the exporter's own hero code calls, loaded
# independently here (this check never calls into export_nano7_map.rb's own
# Ruby) the same way scripts/rpg2k_render_check.rb already exercises
# Game::ChipsetLayout standalone.
load File.join(ROOT, 'mruby-rpg2k/mrblib/game.rb')
load File.join(ROOT, 'scripts/rgss_cruby_compat.rb')

# Mirrors TARGETS in the exporter, which mirrors each firmware's buffers.
TARGETS = {
  'nano7' => { max_w: 128, max_h: 128, max_tiles: 255 },
  'wio' => { max_w: 128, max_h: 128, max_tiles: 192 }
}.freeze
MAP_MAX_W = TARGETS['nano7'][:max_w]
MAP_MAX_H = TARGETS['nano7'][:max_h]
MAX_TILES = TARGETS['nano7'][:max_tiles]
MAP_VERSION = 6
UPPER_NONE = 0xFF
VALID_PASSABLE_BITS = 0x0F # down|left|right|up -- see DIR_BITS in the exporter
TILE_BYTES = 16 * 16       # one palette index per pixel
ENTRY_BYTES = 5            # u8 frame[4] + u8 animation class
ANIM_MAX_FRAMES = 4
ANIM_STATIC = 0
ANIM_CLASSES = [0, 1, 2].freeze
OPAQUE_BIT = 0x8000
TRANSPARENT_INDEX = 0
MAX_PALETTE = 256
# The hero sprite's own fixed geometry -- see HERO_FRAME_W/H in the exporter.
HERO_FRAME_W = 24
HERO_FRAME_H = 32
HERO_FRAME_COUNT = 12 # 4 directions * 3 walk-cycle patterns
HERO_FRAME_BYTES = HERO_FRAME_W * HERO_FRAME_H
HERO_FRAMES_BYTES = HERO_FRAME_COUNT * HERO_FRAME_BYTES

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
  version, hero_present = bytes[4, 2].unpack('CC')
  width, height, start_x, start_y, tile_count, backdrop = bytes[6, 12].unpack('v6')
  palette_count, atlas_count = bytes[18, 4].unpack('v2')
  ab_len, ab_period, c_len, c_period = bytes[22, 4].unpack('C4')
  off = 26
  palette = bytes[off, palette_count * 2].unpack('v*'); off += palette_count * 2
  entries = (0...tile_count).map do |i|
    fields = bytes[off + i * ENTRY_BYTES, ENTRY_BYTES].unpack('C5')
    { frames: fields.first(ANIM_MAX_FRAMES), klass: fields.last }
  end
  off += tile_count * ENTRY_BYTES
  cells = width * height
  lower = bytes[off, cells].unpack('C*'); off += cells
  upper = bytes[off, cells].unpack('C*'); off += cells
  # Passability is a nibble per cell, the even cell in the low half.
  packed = bytes[off, (cells + 1) / 2].unpack('C*'); off += (cells + 1) / 2
  passable = (0...cells).map { |i| i.even? ? (packed[i / 2] & 0x0F) : (packed[i / 2] >> 4) }
  ok(off == bytes.bytesize, "map.bin has #{bytes.bytesize - off} trailing bytes")
  {
    magic: magic, version: version, hero_present: hero_present, width: width,
    height: height, start_x: start_x, start_y: start_y, tile_count: tile_count,
    atlas_count: atlas_count, backdrop: backdrop, palette: palette,
    entries: entries, ab_len: ab_len, ab_period: ab_period,
    c_len: c_len, c_period: c_period,
    lower: lower, upper: upper, passable: passable
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
    check("map #{map_id}: hero_present is a bool") do
      ok [0, 1].include?(map[:hero_present]), map[:hero_present]
    end
    check("map #{map_id}: tiles.bin size matches atlas_count (+ hero frames)") do
      expected = map[:atlas_count] * TILE_BYTES
      expected += HERO_FRAMES_BYTES if map[:hero_present] == 1
      ok tiles_bytes.bytesize == expected, "#{tiles_bytes.bytesize} != #{expected}"
    end
    check("map #{map_id}: every entry names real atlas slots and a real clock") do
      bad = map[:entries].reject { |e| e[:frames].all? { |f| f < map[:atlas_count] } }
      ok bad.empty?, "#{bad.size} entries point past the atlas, e.g. #{(bad.first || {})[:frames].inspect}"
      klasses = map[:entries].map { |e| e[:klass] }.uniq
      ok (klasses - ANIM_CLASSES).empty?, "unknown animation classes #{(klasses - ANIM_CLASSES).inspect}"
    end
    check("map #{map_id}: a still entry is one picture, a moving one is not") do
      map[:entries].each_with_index do |e, i|
        if e[:klass] == ANIM_STATIC
          ok e[:frames].uniq.size == 1, "entry #{i} is static but names #{e[:frames].uniq.size} pictures"
        else
          ok e[:frames].uniq.size > 1, "entry #{i} is animated but names one picture"
        end
      end
    end
    check("map #{map_id}: both animation clocks are usable") do
      ok map[:ab_len].between?(1, ANIM_MAX_FRAMES), "ab_len #{map[:ab_len]}"
      ok map[:c_len].between?(1, ANIM_MAX_FRAMES), "c_len #{map[:c_len]}"
      ok map[:ab_period] >= 1 && map[:c_period] >= 1,
         "periods #{map[:ab_period]}/#{map[:c_period]}"
    end
    check("map #{map_id}: every phase of every entry resolves") do
      bad = map[:entries].reject do |e|
        len = case e[:klass]
              when 1 then map[:ab_len]
              when 2 then map[:c_len]
              else 1
              end
        e[:frames].first(len).all? { |f| f < map[:atlas_count] }
      end
      ok bad.empty?, "#{bad.size} entries have a phase pointing past the atlas"
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
    check("map #{map_id}: atlas pictures are deduplicated") do
      slots = (0...map[:atlas_count]).map { |i| tiles[i * TILE_BYTES, TILE_BYTES] }
      ok slots.uniq.size == slots.size, "#{slots.size - slots.uniq.size} duplicate atlas pictures"
    end
    check("map #{map_id}: entries are deduplicated") do
      keys = map[:entries].map { |e| [e[:klass], e[:frames]] }
      ok keys.uniq.size == keys.size, "#{keys.size - keys.uniq.size} duplicate entries"
    end
    check("map #{map_id}: backdrop is opaque or absent") do
      bd = map[:backdrop]
      ok bd.zero? || (bd & OPAQUE_BIT) != 0, "0x%04x" % bd
    end
    check("map #{map_id}: every lower-layer index resolves into the entries") do
      bad = map[:lower].reject { |i| i < map[:tile_count] }
      ok bad.empty?, "#{bad.size} out-of-range indices, e.g. #{bad.first}"
    end
    check("map #{map_id}: every upper-layer index resolves to an entry or is NONE") do
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

# --no-animate is the fallback for an export that will not otherwise fit. It
# must be the animated export's *first frame*, not a different map: same
# dimensions and start, and every cell drawing the very pixels the animated
# export draws at phase 0. (Entry numbering may legitimately differ -- with
# nothing to animate, entries that differed only in later frames merge -- so
# this compares pictures, not indices.)
def cell_pictures(dir)
  map = read_map_bin(File.join(dir, 'map.bin'))
  tiles = File.binread(File.join(dir, 'tiles.bin'))
  picture = lambda do |entry_index|
    return nil if entry_index == UPPER_NONE
    return :bad if entry_index >= map[:tile_count]
    slot = map[:entries][entry_index][:frames][0]
    tiles[slot * TILE_BYTES, TILE_BYTES]
  end
  [map, map[:lower].map(&picture), map[:upper].map(&picture)]
end

def check_no_animate(game_dir, map_id)
  Dir.mktmpdir('n7anim') do |animated_dir|
    Dir.mktmpdir('n7still') do |still_dir|
      _o, _e, animated_status =
        Open3.capture3('ruby', EXPORTER, game_dir, map_id.to_s, animated_dir)
      stdout, stderr, status =
        Open3.capture3('ruby', EXPORTER, '--no-animate', game_dir, map_id.to_s, still_dir)
      check("map #{map_id} (--no-animate): exporter exits 0") do
        ok status.success?, "exit #{status.exitstatus}: #{stderr}"
      end
      next unless status.success? && animated_status.success?

      still, still_lower, still_upper = cell_pictures(still_dir)
      animated, anim_lower, anim_upper = cell_pictures(animated_dir)

      check("map #{map_id} (--no-animate): nothing animates") do
        moving = still[:entries].count { |e| e[:klass] != ANIM_STATIC }
        ok moving.zero?, "#{moving} entries still move"
        ok still[:entries].all? { |e| e[:frames].uniq.size == 1 },
           'a still entry names more than one picture'
        ok stdout.include?('0 animated'), stdout
      end
      check("map #{map_id} (--no-animate): it is the animated export's first frame") do
        ok still[:width] == animated[:width] && still[:height] == animated[:height],
           'dimensions differ'
        ok still[:start_x] == animated[:start_x] && still[:start_y] == animated[:start_y],
           'start position differs'
        ok still_lower == anim_lower, 'a lower-layer cell draws different pixels'
        ok still_upper == anim_upper, 'an upper-layer cell draws different pixels'
      end
      check("map #{map_id} (--no-animate): the atlas holds no unused frames") do
        ok still[:atlas_count] <= animated[:atlas_count],
           "#{still[:atlas_count]} pictures against the animated export's #{animated[:atlas_count]}"
      end
    end
  end
end

# Independent verification of the hero geometry the exporter's
# composite_hero_frame relies on: Game::CharSet.frame_rect never returns a
# rectangle outside the real CharSet PNG it names, for every direction and
# pattern, and the PNG's own colour key (like a chipset's) never comes out
# as an opaque pixel.
#
# Not run through the exporter's own db-driven leader lookup: this repo's
# only real RPG2000/2003 test-bed data has no project whose *initial* party
# actually carries a static CharSet (see the limitations note atop the
# exporter -- Nepheshel's own default leader is a blank-charset placeholder
# a runtime Change Sprite Association event fills in later, mtf-meido-
# action's chipsets are not the 256-colour PNGs this exporter requires at
# all). `charset_name`/`charset_index` are passed in explicitly instead, so
# this still exercises the exact geometry and pixel-decode calls the
# exporter's hero path makes, against a real CharSet PNG this test bed does
# ship, just not by way of a real project's own database.
def check_hero_geometry(png_path, charset_index)
  check("hero geometry: #{File.basename(png_path)}##{charset_index}") do
    ok File.file?(png_path), "no such file: #{png_path}"
    bmp = RGSS::Bitmap.allocate
    ok bmp.send(:_init_file, png_path, true), "failed to decode #{png_path}"
    pal0 = png_palette0(png_path)
    ok pal0, "no PLTE in #{png_path}"
    key = pack1555(*pal0)

    Game::CharSet::DIR_ROW.each_key do |dir|
      [0, 1, 2].each do |pattern|
        rx, ry, rw, rh = Game::CharSet.frame_rect(charset_index, dir, pattern)
        ok rw == HERO_FRAME_W && rh == HERO_FRAME_H,
           "frame_rect(#{charset_index}, #{dir}, #{pattern}) is #{rw}x#{rh}, " \
           "not #{HERO_FRAME_W}x#{HERO_FRAME_H}"
        ok rx >= 0 && ry >= 0 && rx + rw <= bmp.width && ry + rh <= bmp.height,
           "frame_rect(#{charset_index}, #{dir}, #{pattern}) = " \
           "[#{rx},#{ry},#{rw},#{rh}] is outside the #{bmp.width}x#{bmp.height} PNG"

        opaque_key = false
        rh.times do |yy|
          rw.times do |xx|
            r, g, b, a = bmp.bmp_read(rx + xx, ry + yy)
            next if a < 128
            opaque_key = true if pack1555(r, g, b) == key
          end
        end
        ok !opaque_key,
           "frame_rect(#{charset_index}, #{dir}, #{pattern}) draws the colour key opaque"
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
  check_no_animate(game_dir, id)
end

# See check_hero_geometry's own comment: this test bed's own default party
# has no static hero to export (Nepheshel's own database row is a blank
# placeholder a runtime event fills in), so this checks the same geometry
# and pixel-decode calls the exporter's hero path makes directly, against
# the real CharSet a runtime Change Sprite Association actually assigns --
# "mainchr", index 4, per mruby-lcf/mrblib/schema.rb's own SAVE_PARTY_ACTOR
# comment (confirmed against genuine RPG_RT.exe under wine) -- rather than
# through a full db-driven export.
mainchr = File.join(game_dir, 'CharSet', 'mainchr.png')
check_hero_geometry(mainchr, 4) if File.file?(mainchr)

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
