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
#     read the chipset PNG without a native build. It is loaded with RPG
#     Maker's "palette index 0 is transparent" flag, the same way
#     Scene::Map#load_chipset_graphic does (`Bitmap.new "ChipSet/#{name}",
#     true`) -- without it the colour key bakes into the atlas as a solid
#     colour (Nepheshel's chipsets key on (255, 103, 139), which is what the
#     magenta cells of the first version of this exporter were).
#
# so the on-device C code never parses LCF or composites autotiles: it reads
# two flat files and indexes arrays.
#
# Limitations (see docs/adr/0061 for the full rationale):
#   * one static map per export -- no map tree, no teleport/transitions.
#   * animation is the water autotiles, the block-C animated tiles and the
#     party leader's own walk cycle, at RPG2000's own rates -- the export
#     asks Game::ChipsetLayout.anim_ab/.anim_c and Game::CharSet::WALK_
#     PATTERNS what those are rather than restating them. Everything else an
#     RPG2000 map animates (events, pictures, weather) needs the interpreter
#     and is out of scope. The hero sprite is the project's *initial* party
#     leader (RPG_RT.ldb's own System.party / player rows) -- there is no
#     live game state to ask instead, so a Change Hero Graphic event command
#     or a mid-game party swap is not reflected.
#   * per-pixel transparency is one bit, not an alpha channel: RPG Maker's
#     colour key is binary, so a pixel is either opaque or absent and the
#     device composites upper over lower with a test, not a blend. It is
#     palette index 0, so transparency costs nothing per pixel.
#   * a map's parallax background becomes a single backdrop colour. A chipset
#     may leave a lower-layer tile wholly transparent -- Nepheshel's map 1 is
#     an island whose entire sea is an empty water autotile over the "BG"
#     panorama -- and the genuine runtime shows the panorama through it. A
#     panorama image does not fit this device's budget, so the export reduces
#     it to its average colour and the device paints that behind the map.
#   * events, message boxes, battle and everything interpreter-driven are out
#     of scope entirely; this is a walkable map, not a playable game.
#
# Usage:
#   ruby scripts/export_nano7_map.rb [--target nano7|wio] \
#        GAME_DIR MAP_ID OUT_DIR [START_X START_Y]
#
# --target picks the device the export has to fit (default nano7). Each
# target's caps are the sizes of the static buffers that device's firmware
# declares, so an export that does not fit is refused here rather than
# failing to load on the device. --no-animate freezes every tile at its first
# frame, which is what this exporter did before v5: it costs a map its water
# but spends the fewest atlas slots, so it is the fallback when an animated
# export does not fit.
#
# GAME_DIR is an RPG2000/2003 project directory (containing RPG_RT.ldb/.lmt
# and Map####.lmu files). MAP_ID is the numeric map id (e.g. 1 for
# Map0001.lmu). OUT_DIR receives map.bin and tiles.bin. START_X/START_Y
# override the player start position; with no override, the script uses the
# map tree's own start position (RPG_RT.lmt initial_x/initial_y) when MAP_ID
# is the project's configured start map, or the map's center otherwise.
#
# Output format (v6, both files little-endian):
#
#   map.bin   'N7WM' | u8 version=6 | u8 hero_present | u16 w | u16 h
#             | u16 start_x | u16 start_y | u16 entry_count | u16 backdrop
#             | u16 palette_count | u16 atlas_count
#             | u8 ab_len | u8 ab_period | u8 c_len | u8 c_period
#             | u16 palette[palette_count]
#             | entry[entry_count]: u8 frame[4] | u8 anim_class
#             | u8 lower[w*h] | u8 upper[w*h] | u4 passable[w*h]
#   tiles.bin atlas_count * 256 bytes, row-major within each 16x16 tile: one
#             palette index per pixel; then, only when hero_present is 1, 12
#             more frames of 24x32 (768) bytes each, same encoding -- the
#             party leader's own CharSet, in [direction][pattern] order
#             (up/right/down/left rows -- Game::CharSet::DIR_ROW's own order
#             -- of 3 walk-cycle patterns each).
#
# A cell names an *entry*, not a picture: an entry is up to four atlas slots
# and the class that says which of RPG2000's two animation clocks advances
# through them (0 static, 1 the water autotiles, 2 the block-C animated
# tiles). A still tile is one slot and class 0, so animation costs nothing
# where there is none -- 477 of Nepheshel's 543 maps animate no tile at all.
#
# A cell costs 2.5 bytes. An atlas index is a byte (0xFF on the upper layer
# means "no tile here"), which caps an export at 255 entries -- no map in the
# test data comes near it, the largest needing 146 -- and passability is four
# direction bits, so two cells share a byte, the even cell in the low nibble.
#
# Colours are ARGB1555 (bit 15 "opaque", then r5g5b5) and live only in the
# palette; index 0 is the transparent slot, so a pixel is one byte. That is
# not a quantisation: an RPG Maker chipset is a 256-colour image to begin
# with, and one map draws a subset of it (15 to 133 distinct colours across
# Nepheshel's 543 maps), so the palette is the source data's own, and the
# export is refused rather than dithered if a chipset somehow exceeds 255
# opaque colours. Per-pixel bytes rather than 16-bit colour halves the atlas
# again -- it is the largest thing either device keeps in RAM.
#
# Exits non-zero (with a clear message) if the map's dimensions or distinct
# composited tile count exceed the target's caps (TARGETS below, mirrored in
# app/nano7/rpg2k_walk/rpg2k_walk.c and app/wio/src/walk_main.cxx) -- no
# silent truncation.

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

# The devices that run this export, and the buffers each one can afford.
# Mirrored in that target's firmware, where the same numbers size the static
# arrays: app/nano7/rpg2k_walk/rpg2k_walk.c (kept well under the ~512 KB
# BSS_VA..LINK_VA gap in NanoApps' sdk/hb_app.mk) and
# app/wio/src/walk_main.cxx (192 KB of SRAM for everything, so smaller).
# MAX_TILES can never exceed 255: an atlas index is one byte on-device and
# 0xFF is the upper layer's "no tile" sentinel (RW_MAX_TILES in the core).
TARGETS = {
  'nano7' => { max_w: 128, max_h: 128, max_tiles: 255 },
  'wio' => { max_w: 128, max_h: 128, max_tiles: 192 }
}.freeze
DEFAULT_TARGET = 'nano7'
TS = Game::ChipsetLayout::TS # 16

MAGIC = 'N7WM'
VERSION = 6
UPPER_NONE = 0xFF

# ARGB1555 (see the format note at the top): bit 15 opaque, then r5g5b5.
OPAQUE_BIT = 0x8000
TRANSPARENT = 0x0000

# Palette index 0 is the transparent slot, so opaque colours run 1..255.
TRANSPARENT_INDEX = 0
MAX_PALETTE = 256

# The hero sprite's own geometry (Game::CharSet::WIDTH/HEIGHT, DIR_ROW,
# WALK_PATTERNS): four directions, three walk-cycle patterns each, in the
# same [direction][pattern] order rpg2k_walk_core.c's rw_compose_hero reads.
# A fixed 12-frame block, not sized by anything the map itself contains, so
# it costs every export the same tiles.bin bytes whether or not a hero was
# actually found (RW_HERO_FRAMES_BYTES in the core).
HERO_FRAME_W = Game::CharSet::WIDTH
HERO_FRAME_H = Game::CharSet::HEIGHT
HERO_ROW_DIR = Game::CharSet::DIR_ROW.invert.freeze # row (0..3) -> numpad dir
HERO_PATTERNS = [0, 1, 2].freeze

# An atlas slot is named by a byte inside an entry, and an entry by a byte in
# a cell (with 0xFF reserved for "no upper tile"), so neither can pass 255
# whatever a target's buffers allow -- see MAX_ATLAS below.

# An entry's animation class: which of RPG2000's clocks moves it, if any.
ANIM_STATIC = 0
ANIM_WATER = 1  # blocks A/B, Game::ChipsetLayout.anim_ab
ANIM_BLOCK_C = 2 # block C, Game::ChipsetLayout.anim_c
ANIM_MAX_FRAMES = 4

DIR_DOWN = 2
DIR_LEFT = 4
DIR_RIGHT = 6
DIR_UP = 8
DIR_BITS = { DIR_DOWN => 0x01, DIR_LEFT => 0x02, DIR_RIGHT => 0x04, DIR_UP => 0x08 }.freeze

def usage_abort(msg)
  warn msg
  warn 'Usage: ruby scripts/export_nano7_map.rb [--target nano7|wio] ' \
       'GAME_DIR MAP_ID OUT_DIR [START_X START_Y]'
  exit 1
end

argv = ARGV.dup
target_name = DEFAULT_TARGET
animate = true
until argv.empty?
  case argv.first
  when '--target' then argv.shift; target_name = argv.shift.to_s
  when /\A--target=(.+)\z/ then target_name = Regexp.last_match(1); argv.shift
  when '--no-animate' then argv.shift; animate = false
  when '--animate' then argv.shift; animate = true
  else break
  end
end
target = TARGETS[target_name]
usage_abort("unknown target #{target_name.inspect}; one of #{TARGETS.keys.join(', ')}") if target.nil?
MAP_MAX_W = target[:max_w]
MAP_MAX_H = target[:max_h]
MAX_TILES = target[:max_tiles]
# The device holds one atlas, sized by the same cap: a slot and an entry cost
# it the same buffer.
MAX_ATLAS = target[:max_tiles]

game_dir, map_id_arg, out_dir, start_x_arg, start_y_arg = argv
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
  usage_abort("map #{width}x#{height} exceeds on-device bounds #{MAP_MAX_W}x#{MAP_MAX_H} " \
              "for target #{target_name}")
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

# `true` is RPG Maker's colour-key flag: palette index 0 of a chipset is
# transparent, not a colour. Scene::Map#load_chipset_graphic passes it for
# the real renderer, and this export must agree with it -- see the header.
chipset_bmp = RGSS::Bitmap.allocate
usage_abort("failed to decode chipset PNG: #{chipset_path}") unless chipset_bmp.send(:_init_file, chipset_path, true)

cset = Game::ChipSet.new(db, lmu.chipset_id)

# ---- hero sprite ------------------------------------------------------------

# The project's *initial* party leader (RPG_RT.ldb's own System.party --
# Game::Party#restore's own `db.system.party || []`, first entry -- and that
# actor's own player row), the same source Scene::Map#load_charset draws
# from at New Game. There is no live game state a host-side export can ask
# instead, so this is a best-effort default, not a snapshot of any
# particular save (see the limitations above): a party a title-screen event
# reassembles before the player ever sees a map, or a mid-game Change Hero
# Graphic, is not reflected.
#
# Missing or blank is not an error -- unlike the chipset, a hero sprite is
# an enhancement over the walk port's original marker, and treating a small,
# custom, or title-screen-only project's empty initial party as fatal would
# regress every map that exported fine before this format version.
hero_bmp = nil
hero_charset_index = 0
# db[22], not db.system: under CRuby `system` resolves to Kernel#system
# before method_missing ever sees it (AGENTS.md documents the identical trap
# for `save[101]`/`save.system`; mruby has no such collision, which is why
# mruby-rpg2k's own game.rb can spell this `db.system.party`).
party_ids = db[22].party || []
leader = party_ids.first && db.player[party_ids.first]
hero_charset_name = leader && leader.charset_name.to_s
if hero_charset_name && !hero_charset_name.empty?
  hero_charset_index = leader.charset_index || 0
  if hero_charset_index < 0 || hero_charset_index > 7
    warn "[nano7] party leader's CharSet index #{hero_charset_index} is out of the " \
         '0..7 a CharSet PNG holds; exporting without a hero sprite'
  else
    hero_path = File.join(game_dir, 'CharSet', "#{hero_charset_name}.png")
    if File.file?(hero_path)
      candidate = RGSS::Bitmap.allocate
      # Colour-keyed, same as the chipset -- Scene::Map#load_charset passes
      # the same `true` flag Scene::Map#load_chipset_graphic does.
      if candidate.send(:_init_file, hero_path, true)
        hero_bmp = candidate
      else
        warn "[nano7] failed to decode hero CharSet PNG #{hero_path}; exporting without a hero sprite"
      end
    else
      warn "[nano7] hero CharSet image not found: #{hero_path}; exporting without a hero sprite"
    end
  end
end

# ---- backdrop colour -------------------------------------------------------

# What shows through the holes: the average colour of the map's parallax
# background, or black when it has none (see the limitations above). Sampled
# on a coarse grid rather than per pixel -- bmp_read is pure Ruby here and a
# panorama is commonly 640x480, while an average does not need every pixel.
def backdrop_for(game_dir, lmu)
  return 0 unless lmu.parallax_flag
  name = lmu.parallax_name.to_s
  return 0 if name.empty?

  path = %w[png xyz bmp].map { |ext| File.join(game_dir, 'Panorama', "#{name}.#{ext}") }.find { |f| File.file?(f) }
  if path.nil?
    warn "[nano7] parallax background '#{name}' not found under #{File.join(game_dir, 'Panorama')}; backdrop falls back to black"
    return 0
  end

  bmp = RGSS::Bitmap.allocate
  if bmp.send(:_init_file, path).nil?
    warn "[nano7] failed to decode parallax background #{path}; backdrop falls back to black"
    return 0
  end

  step_x = [bmp.width / 128, 1].max
  step_y = [bmp.height / 128, 1].max
  r_sum = g_sum = b_sum = n = 0
  (0...bmp.height).step(step_y) do |y|
    (0...bmp.width).step(step_x) do |x|
      r, g, b, a = bmp.bmp_read(x, y)
      next if a < 128
      r_sum += r
      g_sum += g
      b_sum += b
      n += 1
    end
  end
  return 0 if n.zero?

  OPAQUE_BIT | (to5(r_sum / n) << 10) | (to5(g_sum / n) << 5) | to5(b_sum / n)
end

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

# ---- animation, asked of the engine's own code -----------------------------

# RPG2000 animates two classes of tile on two clocks, and mruby-rpg2k already
# implements both: Game::ChipsetLayout.anim_ab walks the water autotiles
# (blocks A/B) and .anim_c the block-C animated tiles. Rather than restate
# either rule -- the step lengths, the ping-pong the water does for one
# animation_type and not the other -- ask the real functions: probe for the
# frame at which each first changes (its step), then sample it at its own
# step boundaries and take the shortest repeat. A chipset this export has
# never seen still animates the way the engine would animate it.
def anim_step_frames(max_probe = 240)
  first = yield(0)
  (1..max_probe).each { |f| return f if yield(f) != first }
  max_probe
end

def anim_cycle(step, max_len)
  values = (0...(2 * max_len)).map { |k| yield(k * step) }
  (1..max_len).each do |p|
    return values.first(p) if (0...max_len).all? { |i| values[i] == values[i + p] }
  end
  values.first(max_len)
end

ab_period = anim_step_frames { |f| Game::ChipsetLayout.anim_ab(f, cset.animation_type, cset.animation_speed) }
c_period = anim_step_frames { |f| Game::ChipsetLayout.anim_c(f) }
ab_cycle = anim_cycle(ab_period, ANIM_MAX_FRAMES) { |f| Game::ChipsetLayout.anim_ab(f, cset.animation_type, cset.animation_speed) }
c_cycle = anim_cycle(c_period, ANIM_MAX_FRAMES) { |f| Game::ChipsetLayout.anim_c(f) }
unless animate
  ab_cycle = [ab_cycle.first]
  c_cycle = [c_cycle.first]
end

# ---- build the deduplicated tile atlas and entry table ---------------------

entry_of_tile = {} # tile id -> entry index
entry_by_key = {} # [class, slots] -> entry index
entries = [] # entry index -> [class, [atlas slots]]
atlas_by_pixels = {} # packed pixel string -> atlas slot
atlas_pixels = [] # atlas slot -> 256 palette indices (top-left origin, row-major)

# The map's palette, built as the tiles are composited: ARGB1555 colour ->
# index, with 0 reserved for "transparent" (see the format note at the top).
palette = [TRANSPARENT]
palette_index = {}

def palette_index_for(colour, palette, palette_index)
  index = palette_index[colour]
  return index if index

  if palette.size >= MAX_PALETTE
    usage_abort("map needs more than #{MAX_PALETTE - 1} opaque colours; " \
                'this chipset is not a 256-colour image (see the format note)')
  end
  index = palette.size
  palette_index[colour] = index
  palette << colour
  index
end

# 8-bit channel -> 5 bits, rounded rather than truncated (>> 3 darkens every
# channel by up to 7/255, which is visible across a whole tile of flat colour).
def to5(v)
  (v * 31 + 127) / 255
end

def composite_tile(bmp, tile_id, abf, cf, palette, palette_index)
  pixels = Array.new(TS * TS, TRANSPARENT_INDEX)
  Game::ChipsetLayout.quads(tile_id, abf, cf).each do |dx, dy, sx, sy, w, h|
    h.times do |yy|
      w.times do |xx|
        r, g, b, a = bmp.bmp_read(sx + xx, sy + yy)
        # RPG Maker's transparency is a colour key, so the source alpha is
        # 0 or 255 in practice; a PNG tRNS chunk could in principle carry a
        # partial value, and the device composites with a test rather than a
        # blend, so anything half-transparent or more counts as absent.
        next if a < 128
        colour = OPAQUE_BIT | (to5(r) << 10) | (to5(g) << 5) | to5(b)
        pixels[(dy + yy) * TS + (dx + xx)] =
          palette_index_for(colour, palette, palette_index)
      end
    end
  end
  pixels.pack('C*')
end

# Distinct tile ids routinely composite to identical pixels -- an autotile
# whose neighbours differ only where the chipset draws nothing, the blank chip
# reached through several ids, every frame of a water tile the chipset draws
# still -- and the device's caps are on slots and entries, not on ids, so fold
# them together before spending either.
def atlas_slot_for(pixels, atlas_by_pixels, atlas_pixels)
  slot = atlas_by_pixels[pixels]
  return slot if slot

  usage_abort("map needs #{atlas_pixels.size + 1} distinct tile pictures, " \
              "exceeding the on-device cap #{MAX_ATLAS}") if atlas_pixels.size >= MAX_ATLAS
  slot = atlas_pixels.size
  atlas_by_pixels[pixels] = slot
  atlas_pixels << pixels
  slot
end

# The entry a cell names: the atlas slots one tile id cycles through, and the
# clock that moves it. A tile whose frames all composite alike is recorded as
# static, so a chipset that draws its water without animating it costs the
# device nothing at run time.
def entry_for(tile_id, bmp, ctx)
  index = ctx[:entry_of_tile][tile_id]
  return index if index

  klass, phases =
    case Game::ChipsetLayout.block(tile_id)
    when :water then [ANIM_WATER, ctx[:ab_cycle].map { |ab| [ab, 0] }]
    when :animated then [ANIM_BLOCK_C, ctx[:c_cycle].map { |cf| [0, cf] }]
    else [ANIM_STATIC, [[0, 0]]]
    end

  slots = phases.map do |abf, cf|
    atlas_slot_for(composite_tile(bmp, tile_id, abf, cf, ctx[:palette], ctx[:palette_index]),
                   ctx[:atlas_by_pixels], ctx[:atlas_pixels])
  end
  if slots.uniq.size == 1
    klass = ANIM_STATIC
    slots = [slots.first]
  end

  key = [klass, slots]
  index = ctx[:entry_by_key][key]
  if index.nil?
    usage_abort("map uses #{ctx[:entries].size + 1} distinct tiles, " \
                "exceeding the on-device cap #{MAX_TILES}") if ctx[:entries].size >= MAX_TILES
    index = ctx[:entries].size
    ctx[:entry_by_key][key] = index
    ctx[:entries] << [klass, slots]
  end
  ctx[:entry_of_tile][tile_id] = index
  index
end

lower_out = Array.new(width * height)
upper_out = Array.new(width * height)
passable_out = Array.new(width * height)

entry_ctx = {
  entry_of_tile: entry_of_tile, entry_by_key: entry_by_key, entries: entries,
  atlas_by_pixels: atlas_by_pixels, atlas_pixels: atlas_pixels,
  palette: palette, palette_index: palette_index,
  ab_cycle: ab_cycle, c_cycle: c_cycle
}

(0...(width * height)).each do |i|
  lo = lower_layer[i]
  up = upper_layer[i]
  lower_out[i] = entry_for(lo, chipset_bmp, entry_ctx)
  upper_out[i] = if Game::ChipsetLayout.upper_blank?(up)
                   UPPER_NONE
                 else
                   entry_for(up, chipset_bmp, entry_ctx)
                 end

  flags = 0
  DIR_BITS.each do |dir, bit|
    flags |= bit if cset.passable_tile?(lo, up, dir)
  end
  passable_out[i] = flags
end

backdrop = backdrop_for(game_dir, lmu)

# ---- hero frames, precomposited the same way the atlas is -----------------

# A straight sub-rect read, not Game::ChipsetLayout.quads' autotile assembly
# -- a CharSet frame is one rectangle, not four independently-chosen corner
# quarters -- but the same colour-key test and the same shared palette, so a
# hero pixel and a tile pixel of the same source colour are the same index.
def composite_hero_frame(bmp, rx, ry, rw, rh, palette, palette_index)
  pixels = Array.new(rw * rh, TRANSPARENT_INDEX)
  rh.times do |yy|
    rw.times do |xx|
      r, g, b, a = bmp.bmp_read(rx + xx, ry + yy)
      next if a < 128
      colour = OPAQUE_BIT | (to5(r) << 10) | (to5(g) << 5) | to5(b)
      pixels[yy * rw + xx] = palette_index_for(colour, palette, palette_index)
    end
  end
  pixels.pack('C*')
end

hero_present = !hero_bmp.nil?
hero_frames_bytes =
  if hero_present
    HERO_ROW_DIR.keys.sort.map do |row|
      dir = HERO_ROW_DIR[row]
      HERO_PATTERNS.map do |pattern|
        rx, ry, rw, rh = Game::CharSet.frame_rect(hero_charset_index, dir, pattern)
        composite_hero_frame(hero_bmp, rx, ry, rw, rh, palette, palette_index)
      end
    end.flatten.join
  else
    ''
  end

# ---- write map.bin -----------------------------------------------------

Dir.mkdir(out_dir) unless Dir.exist?(out_dir)

File.open(File.join(out_dir, 'map.bin'), 'wb') do |f|
  f.write(MAGIC)
  f.write([VERSION, hero_present ? 1 : 0].pack('CC'))
  f.write([width, height, start_x, start_y, entries.size, backdrop].pack('v6'))
  f.write([palette.size, atlas_pixels.size].pack('v2'))
  f.write([ab_cycle.size, ab_period, c_cycle.size, c_period].pack('C4'))
  f.write(palette.pack('v*'))
  # One entry: its atlas slots, padded to four with its first (a phase a
  # shorter cycle never reaches still reads as the tile itself), then the
  # clock that moves it.
  entries.each do |klass, slots|
    padded = slots + Array.new(ANIM_MAX_FRAMES - slots.size, slots.first)
    f.write((padded + [klass]).pack('C5'))
  end
  f.write(lower_out.pack('C*'))
  f.write(upper_out.pack('C*'))
  # Two cells per byte, the even cell in the low nibble -- see the format
  # note; a map with an odd number of cells pads the last byte's high nibble
  # with zeroes, which no cell reads.
  f.write(passable_out.each_slice(2).map { |lo, hi| lo | ((hi || 0) << 4) }.pack('C*'))
end

File.open(File.join(out_dir, 'tiles.bin'), 'wb') do |f|
  atlas_pixels.each { |px| f.write(px) }
  f.write(hero_frames_bytes) if hero_present
end

# The chipset path is part of the output line so scripts/export_nano7_map_check.rb
# can read the very palette this export keyed on, and check no opaque atlas
# pixel carries the colour key.
animated_entries = entries.count { |klass, _| klass != ANIM_STATIC }
hero_msg = hero_present ? "hero '#{hero_charset_name}'##{hero_charset_index}" : 'no hero'
puts "wrote #{out_dir}/map.bin (target #{target_name}, #{width}x#{height}, " \
     "start #{start_x},#{start_y}) " \
     "and #{out_dir}/tiles.bin (#{entries.size} entries, #{animated_entries} animated, " \
     "#{atlas_pixels.size} tiles, #{entry_of_tile.size} ids, " \
     "#{palette.size} palette entries, backdrop 0x%04x, #{hero_msg}) from #{chipset_path}" % backdrop
