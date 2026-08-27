#!/usr/bin/env ruby
# encoding: UTF-8
#
# Export one RPG Maker 2000/2003 map into the compact binary format the
# iPod Nano 7th-gen homebrew app (app/nano7/rpg2k_walk) reads on-device.
#
# NanoApps (the N7G homebrew SDK, see docs/adr/0061) caps a compiled app
# image at roughly 500 KB, which rules out running this engine's mruby/RGSS
# interpreter on the device (see the ADR). This script instead does the LCF
# parsing and chipset compositing *once, on the host*, using the exact same
# pure-Ruby sources the rest of this repo already loads under plain CRuby:
#
#   * mruby-lcf/mrblib/{lcf,schema}.rb   -- the LCF/BER map+database reader,
#     same loading pattern as scripts/lcf_save_check.rb / lcf_testbed_check.rb.
#   * mruby-rpg2k/mrblib/game.rb         -- Game::ChipsetLayout (tile-id ->
#     chipset source-rect geometry, including the autotile quarter-tile
#     assembly) and Game::ChipSet (passability), the same pure-geometry module
#     scripts/rpg2k_render_check.rb already exercises standalone.
#   * scripts/rgss_cruby_compat.rb       -- RGSS::Bitmap's PNG decoder, to
#     read the chipset PNG without a native build.
#
# so the on-device C code never parses LCF or composites autotiles: it reads
# two flat files and indexes arrays.
#
# Limitations (see docs/adr/0061 for the full rationale):
#   * one static map per export -- no map tree, no teleport/transitions.
#   * one animation frame per tile id (abf=0, cf=0) -- water/ground/terrain
#     autotiles render their first frame, never animate on-device.
#   * events, message boxes, battle and everything interpreter-driven are out
#     of scope entirely; this is a walkable map, not a playable game.
#
# Usage:
#   ruby scripts/export_nano7_map.rb GAME_DIR MAP_ID OUT_DIR [START_X START_Y]
#
# GAME_DIR is an RPG2000/2003 project directory (containing RPG_RT.ldb/.lmt
# and Map####.lmu files). MAP_ID is the numeric map id (e.g. 1 for
# Map0001.lmu). OUT_DIR receives map.bin and tiles.bin. START_X/START_Y
# override the player start position; with no override, the script uses the
# map tree's own start position (RPG_RT.lmt initial_x/initial_y) when MAP_ID
# is the project's configured start map, or the map's center otherwise.
#
# Exits non-zero (with a clear message) if the map's dimensions or distinct
# on-screen tile count exceed the on-device caps (MAP_MAX_W/H, MAX_TILES
# below, mirrored in app/nano7/rpg2k_walk/rpg2k_walk.c) -- no silent
# truncation.

require 'stringio'

module LCF
  # uni-algo stand-in, same shim scripts/lcf_save_check.rb and
  # scripts/lcf_testbed_check.rb use to load the schema under plain CRuby.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
  module_function :cp932_to_utf8

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

ROOT = File.expand_path('..', __dir__)
load File.join(ROOT, 'mruby-lcf/mrblib/lcf.rb')
load File.join(ROOT, 'mruby-lcf/mrblib/schema.rb')
load File.join(ROOT, 'mruby-rpg2k/mrblib/game.rb')
load File.join(ROOT, 'scripts/rgss_cruby_compat.rb')

# Mirrored in app/nano7/rpg2k_walk/rpg2k_walk.c's static array bounds. Sized
# to keep the on-device .bss well under the ~512 KB BSS_VA..LINK_VA gap in
# NanoApps' sdk/hb_app.mk -- see the size-budget comment in rpg2k_walk.c.
MAP_MAX_W = 128
MAP_MAX_H = 128
MAX_TILES = 256
TS = Game::ChipsetLayout::TS # 16

MAGIC = 'N7WM'
UPPER_NONE = 0xFFFF

DIR_DOWN = 2
DIR_LEFT = 4
DIR_RIGHT = 6
DIR_UP = 8
DIR_BITS = { DIR_DOWN => 0x01, DIR_LEFT => 0x02, DIR_RIGHT => 0x04, DIR_UP => 0x08 }.freeze

def usage_abort(msg)
  warn msg
  warn 'Usage: ruby scripts/export_nano7_map.rb GAME_DIR MAP_ID OUT_DIR [START_X START_Y]'
  exit 1
end

game_dir, map_id_arg, out_dir, start_x_arg, start_y_arg = ARGV
usage_abort('missing arguments') if game_dir.nil? || map_id_arg.nil? || out_dir.nil?
usage_abort("no such game dir: #{game_dir}") unless Dir.exist?(game_dir)

map_id = Integer(map_id_arg)
map_path = File.join(game_dir, format('Map%04d.lmu', map_id))
usage_abort("no such map: #{map_path}") unless File.file?(map_path)

db = LCF::Database.new(File.open(File.join(game_dir, 'RPG_RT.ldb'), 'rb'))
lmu = LCF::MapUnit.new(File.open(map_path, 'rb'))

width = lmu.width.to_i
height = lmu.height.to_i
if width <= 0 || height <= 0 || width > MAP_MAX_W || height > MAP_MAX_H
  usage_abort("map #{width}x#{height} exceeds on-device bounds #{MAP_MAX_W}x#{MAP_MAX_H}")
end

lower_layer = lmu.lower_layer.to_a
upper_layer = (lmu.upper_layer && lmu.upper_layer.to_a) || Array.new(width * height, 0)
if lower_layer.size != width * height || upper_layer.size != width * height
  usage_abort("map layer size mismatch: expected #{width * height} cells")
end

chipset = db.chipset[lmu.chipset_id]
usage_abort("map ##{map_id} references chipset ##{lmu.chipset_id}, not found in database") if chipset.nil?

chipset_path = File.join(game_dir, 'ChipSet', "#{chipset.chipset_name}.png")
usage_abort("chipset image not found: #{chipset_path} (only PNG chipsets are supported)") unless File.file?(chipset_path)

chipset_bmp = RGSS::Bitmap.allocate
usage_abort("failed to decode chipset PNG: #{chipset_path}") unless chipset_bmp.send(:_init_file, chipset_path)

cset = Game::ChipSet.new(db, lmu.chipset_id)

# Start position: an explicit override, else the map tree's own start
# position when this is the project's configured start map, else the map's
# center as a reasonable default for previewing any other map.
start_x = start_x_arg && Integer(start_x_arg)
start_y = start_y_arg && Integer(start_y_arg)
if start_x.nil? || start_y.nil?
  lmt = LCF::MapTree.new(File.open(File.join(game_dir, 'RPG_RT.lmt'), 'rb'))
  if lmt.initial.initial_map_id.to_i == map_id
    start_x ||= lmt.initial.initial_x.to_i
    start_y ||= lmt.initial.initial_y.to_i
  else
    start_x ||= width / 2
    start_y ||= height / 2
  end
end

# ---- build the deduplicated tile atlas -------------------------------------

atlas_index = {} # tile id -> atlas slot
atlas_pixels = [] # atlas slot -> 256 packed 0xRRGGBB pixels (top-left origin, row-major)

def composite_tile(bmp, tile_id)
  pixels = Array.new(TS * TS, 0)
  Game::ChipsetLayout.quads(tile_id, 0, 0).each do |dx, dy, sx, sy, w, h|
    h.times do |yy|
      w.times do |xx|
        r, g, b, = bmp.bmp_read(sx + xx, sy + yy)
        pixels[(dy + yy) * TS + (dx + xx)] = (r << 16) | (g << 8) | b
      end
    end
  end
  pixels
end

def atlas_slot_for(tile_id, bmp, atlas_index, atlas_pixels)
  slot = atlas_index[tile_id]
  return slot if slot
  usage_abort("map uses #{atlas_index.size + 1} distinct tiles, exceeding on-device cap #{MAX_TILES}") if atlas_index.size >= MAX_TILES
  slot = atlas_index.size
  atlas_index[tile_id] = slot
  atlas_pixels << composite_tile(bmp, tile_id)
  slot
end

lower_out = Array.new(width * height)
upper_out = Array.new(width * height)
passable_out = Array.new(width * height)

(0...(width * height)).each do |i|
  lo = lower_layer[i]
  up = upper_layer[i]
  lower_out[i] = atlas_slot_for(lo, chipset_bmp, atlas_index, atlas_pixels)
  upper_out[i] = Game::ChipsetLayout.upper_blank?(up) ? UPPER_NONE : atlas_slot_for(up, chipset_bmp, atlas_index, atlas_pixels)

  flags = 0
  DIR_BITS.each do |dir, bit|
    flags |= bit if cset.passable_tile?(lo, up, dir)
  end
  passable_out[i] = flags
end

# ---- write map.bin -----------------------------------------------------

Dir.mkdir(out_dir) unless Dir.exist?(out_dir)

File.open(File.join(out_dir, 'map.bin'), 'wb') do |f|
  f.write(MAGIC)
  f.write([1, 0].pack('CC'))
  f.write([width, height, start_x, start_y, atlas_index.size, 0].pack('v6'))
  f.write(lower_out.pack('v*'))
  f.write(upper_out.pack('v*'))
  f.write(passable_out.pack('C*'))
end

File.open(File.join(out_dir, 'tiles.bin'), 'wb') do |f|
  atlas_pixels.each { |px| f.write(px.pack('V*')) }
end

puts "wrote #{out_dir}/map.bin (#{width}x#{height}, start #{start_x},#{start_y}) " \
     "and #{out_dir}/tiles.bin (#{atlas_index.size} tiles)"
