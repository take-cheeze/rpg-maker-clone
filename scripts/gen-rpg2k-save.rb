#!/usr/bin/env ruby
# encoding: UTF-8
#
# Move the party in an existing RPG Maker 2000/2003 `Save<N>.lsd` to a chosen
# map and tile, so both this engine and the genuine RPG_RT.exe can be resumed
# side by side on the same spot.
#
# Why this exists: comparing our renderer against the real runtime on an actual
# game *map* (rather than the title screen) means getting both to the same
# place. Driving them there by counting key presses does not work --
# scripts/compare-nepheshel-wine.bash does exactly that, and the two
# desynchronise through Nepheshel's long *timed* opening, which is why only the
# title screen could be diffed pixel-for-pixel (ADR 0021). Loading a save is not
# timed, so it cannot drift; this puts that save wherever the comparison needs
# it.
#
# WHY IT EDITS A SAVE INSTEAD OF WRITING ONE: `Game::State#to_lsd` can already
# emit a Save<N>.lsd from nothing, and it round-trips through our own parser --
# but the genuine RPG_RT *refuses to load it*, leaving "Continue" dead on the
# title screen. A real save carries sixteen chunks (~11-18 KB); to_lsd emits
# five (~180 bytes), missing the vehicles, pictures, map events, common events
# and three chunks not in our schema at all (102, 112, 200). Editing a genuine
# save sidesteps that entirely: every chunk we do not touch is preserved
# byte-for-byte, which scripts/lcf_save_roundtrip.rb already proves our writer
# does. Making to_lsd's own output loadable is tracked separately in docs/TODO.md.
#
# Get the base save with scripts/gen-lcf-save-wine.bash, which drives EasyRPG
# Player's F9 debug menu under wine to write one without a playthrough.
#
# Like the other host-side checks this loads the mruby/CRuby-common sources
# under CRuby, shimming the parser's one native dependency (LCF.cp932_to_utf8)
# with Ruby's Windows-31J transcoder.
#
# Usage:
#   ruby scripts/gen-rpg2k-save.rb [GAME_DIR] [options]
#     --map ID         map to place the party on (default: leave it where it is)
#     --at X,Y         tile to stand on (default: the map's centre when --map
#                      moves to another map, else unchanged)
#     --facing DIR     down|left|right|up (default: unchanged)
#     --slot N         save slot to edit -> Save0<N>.lsd (default: 1)
#     --out PATH       write here instead of over the input
# GAME_DIR defaults to the RPG2000 test-bed (Nepheshel).

require 'stringio'
require 'optparse'

module LCF
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end

  def utf8_to_cp932(s)
    s.dup.encode('Windows-31J', invalid: :replace, undef: :replace)
     .force_encoding('BINARY')
  end
  module_function :cp932_to_utf8, :utf8_to_cp932
  def self.max_level; MODE == 2003 ? 99 : 50; end
end

ROOT = File.expand_path('..', __dir__)
load File.join(ROOT, 'mruby-lcf', 'mrblib', 'lcf.rb')
load File.join(ROOT, 'mruby-lcf', 'mrblib', 'schema.rb')

# Field ids inside the save's hero chunk (104), per LCF::Schema::SAVE_MOVABLE.
HERO_MAP = 11
HERO_X = 12
HERO_Y = 13
HERO_DIRECTION = 22

DIRECTIONS = { 'up' => 8, 'right' => 6, 'left' => 4, 'down' => 2 }.freeze

options = { slot: 1 }
parser = OptionParser.new do |o|
  o.banner = 'Usage: ruby scripts/gen-rpg2k-save.rb [GAME_DIR] [options]'
  o.on('--map ID', Integer, 'map id to place the party on') { |v| options[:map] = v }
  o.on('--at X,Y', 'tile to stand on') { |v| options[:at] = v }
  o.on('--facing DIR', DIRECTIONS.keys, 'down|left|right|up') { |v| options[:facing] = v }
  o.on('--slot N', Integer, 'save slot to edit (default 1)') { |v| options[:slot] = v }
  o.on('--out PATH', 'write here instead of over the input') { |v| options[:out] = v }
end
rest = parser.parse(ARGV)

game_dir = rest.shift || File.join(ROOT, 'data', 'Nepheshel206beta', 'Nepheshel206Rbeta')
src = File.join(game_dir, format('Save%02d.lsd', options[:slot]))
unless File.exist?(src)
  warn "no #{File.basename(src)} in #{game_dir}."
  warn 'Generate one first:  ./scripts/gen-lcf-save-wine.bash ' + game_dir
  exit 1
end

save = LCF::SaveData.new(File.open(src, 'rb'))
hero = save[104]
unless hero
  warn "#{src} has no hero chunk (104); is it a real save?"
  exit 1
end

from = [hero[HERO_MAP], hero[HERO_X], hero[HERO_Y]]
map_id = options[:map] || from[0]

if options[:at]
  x, y = options[:at].split(',').map { |n| Integer(n) }
elsif map_id == from[0]
  x = from[1]
  y = from[2]
else
  # Landing on another map with no tile given: stand in the middle. It is always
  # in bounds, though possibly unwalkable -- which is fine, since the comparison
  # only needs both runtimes on the same tile, and both will draw the hero there.
  map_path = File.join(game_dir, format('Map%04d.lmu', map_id))
  unless File.exist?(map_path)
    warn "map #{map_id} has no #{File.basename(map_path)} in #{game_dir}"
    exit 1
  end
  map = LCF::MapUnit.new(File.open(map_path, 'rb'))
  x = map.width / 2
  y = map.height / 2
end

hero[HERO_MAP] = map_id
hero[HERO_X] = x
hero[HERO_Y] = y
hero[HERO_DIRECTION] = DIRECTIONS.fetch(options[:facing]) if options[:facing]
# Reading a chunk decodes a detached copy, so the edited chunk has to go back in
# before serialising (same as scripts/lcf_save_roundtrip.rb).
save[104] = hero

moved_maps = map_id != from[0]

out = options[:out] || src
save.save_to(out)

# Read back through the parser so an unloadable result is reported here rather
# than as a dead "Continue" in whichever runtime opens it.
back = LCF::SaveData.new(File.open(out, 'rb'))
got = [back[104][HERO_MAP], back[104][HERO_X], back[104][HERO_Y]]
unless got == [map_id, x, y]
  warn "FAILED: wrote map=#{map_id} (#{x},#{y}) but read back " \
       "map=#{got[0]} (#{got[1]},#{got[2]})"
  exit 1
end

puts "#{out}: map #{from[0]} (#{from[1]},#{from[2]}) -> #{map_id} (#{x},#{y})" \
     "#{options[:facing] ? " facing #{options[:facing]}" : ''}" \
     "#{moved_maps ? ' [map changed: the save keeps the old map event states]' : ''}"
