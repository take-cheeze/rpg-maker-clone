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
# WHY IT EDITS A SAVE INSTEAD OF WRITING ONE: `Game::State#to_lsd` can emit a
# Save<N>.lsd from nothing, and the genuine RPG_RT does load one now (it used to
# refuse them -- the file-screen date defaulted to 0.0, which is 1899-12-30 on
# the OLE scale and reads as an empty slot; see ADR 0021). But a to_lsd save
# carries only the five chunks that model our runtime state: no pictures, no map
# events, no vehicles. It resumes into a valid but *bare* scene, which is no use
# for comparing rendering against the real thing.
#
# Editing a genuine save keeps all of that: every chunk not touched here is
# preserved byte-for-byte, which scripts/lcf_save_roundtrip.rb already proves
# our writer does.
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
#     --clear-scene    drop the running-event continuation (chunk 113) and the
#                      shown pictures (chunk 103), so the save resumes standing
#                      on a plain map with nothing running over it
#     --slot N         save slot to edit -> Save0<N>.lsd (default: 1)
#     --out PATH       write here instead of over the input
# GAME_DIR defaults to the RPG2000 test-bed (Nepheshel).
#
# WHY --clear-scene EXISTS: gen-lcf-save-wine.bash saves through EasyRPG's F9
# debug menu from wherever the game happens to be, and for Nepheshel that is
# mid-opening -- the save carries the opening demo's choice in chunk 113 and its
# backdrop picture in chunk 103. Resuming it puts both runtimes back into that
# cutscene, where the frames drift again for the same reason the key-driven
# harness does: the cutscene is timed. Dropping those two chunks resumes on the
# map itself, which is static until a key is pressed and so can be diffed
# pixel-for-pixel -- and walked, a step at a time, with both runtimes staying in
# lock-step. Everything else in the save (map event positions, the party,
# switches and variables) is preserved byte-for-byte.
#
# One thing --clear-scene cannot restore is the hero *sprite*: this comment
# used to blame that on Set Transparent Flag being on via "chunk 101 field
# 55" -- wrong on two counts, corrected here rather than left to mislead the
# next reader. Field 55 of the *system* chunk (101) is liblcf's own
# `event_message_active` (ShowMessage/ShowChoices/NumberInput bookkeeping),
# not a visibility flag at all, and Set Transparent Flag's own runtime state
# actually lives on the hero's movable record instead (chunk 104, field 24 of
# `LCF::Schema::SAVE_MOVABLE`) -- but checking that field against the
# checked-in `data/Nepheshel206beta` fixture's own `Save01.lsd` (gitignored,
# reused by many prior cycles' own wine probes) shows it already reads 0 (not
# transparent), so transparency was never the actual mechanism either. The
# real cause, per `scripts/rpg2k_save_load_check.rb`'s own established
# finding (see its "leader is not simply chunk 109's party list's first
# entry" comment): this exact save's *actual* party leader, the one genuine
# RPG_RT.exe resolves and shows throughout its own menus, is database actor
# 15 ("デモ用", matching the title chunk's hero_name/level/hp) -- a demo/
# placeholder actor whose own `charset_name` (RPG_RT.ldb chunk 11 field 3) is
# a blank string, not chunk 109's nominal first roster entry (actor 1,
# "リト", which does carry a real "mainchr" charset). `Game::State.from_lsd`
# already promotes the correct leader (actor 15) via that same title-chunk
# fixup, so our own engine resolves the identical blank charset here too --
# a blank charset draws nothing in production in both runtimes alike, not a
# bug, just this particular save's own leader having no assigned graphic at
# capture time. The only reason our own renderer ever shows *anything* at
# this hero position is `Scene::Map`'s own `--test_play`-only debug marker
# for an unavailable CharSet graphic (`mruby-rpg2k/mrblib/scene/map.rb`,
# gated on `parent.test_play`, alpha 0 -- i.e. invisible -- otherwise); that
# marker is exactly what a naive screenshot diff of this save would
# manufacture as a difference, not a genuine rendering gap. Character-sprite rendering
# is therefore compared through the map's *events*, which both runtimes do
# draw regardless of which actor the party leader resolves to -- and that is
# what caught the CharSet colour-key bug.

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

# Top-level save chunks --clear-scene removes, per LCF::Schema::SAVE_DATA.
PICTURES = 103
FOREGROUND_EVENT = 113

# The saved map state (chunk 111), its camera scroll fields, and its
# per-event position/direction snapshot table, per LCF::Schema::SAVE_MAP_EVENT.
MAP_EVENTS = 111
SCROLL_X = 1
SCROLL_Y = 2
EVENTS = 11

# RPG2000 screen geometry, mirroring Game::TILE / RPG2k::WIDTH / RPG2k::HEIGHT
# in the engine (which is mruby-only, so it cannot be loaded here).
TILE = 16
SCREEN_W = 320
SCREEN_H = 240

# The engine's Game.camera_offset: the view's top-left pixel so the hero is
# centred, clamped to the map. Kept in step with mruby-rpg2k/mrblib/game.rb.
def camera_offset(player_px, screen_px, map_px)
  max = map_px - screen_px
  max = 0 if max < 0
  v = player_px - screen_px / 2
  return 0 if v < 0
  return max if v > max
  v
end

DIRECTIONS = { 'up' => 8, 'right' => 6, 'left' => 4, 'down' => 2 }.freeze

# LCF::Schema::SAVE_MOVABLE's own field 22 (which HERO_DIRECTION above points
# at) is documented there as liblcf's own facing enum -- 0=up, 1=right,
# 2=down, 3=left, matching `Game_Character::Direction`'s enum order -- NOT
# this runtime's numpad convention (2/4/6/8) DIRECTIONS holds. Game::CharSet
# ::DIR_ROW (mruby-rpg2k/mrblib/game.rb) is that exact numpad -> liblcf-index
# table, so it doubles as the encoder here (this script cannot load the mruby
# gem, so the table is inlined rather than shared).
#
# Found by hand this cycle: this script used to write DIRECTIONS.fetch(...)
# (the numpad value, e.g. 8 for 'up') straight into field 22 instead of
# converting it first, putting an out-of-range value into a field this
# codebase's own decoder (`EventGraphic.numpad_direction`'s own
# `LCF_DIR_TO_NUMPAD[lcf_dir] || 2` fallback) reads back as facing *down*
# for anything it does not recognise -- silently wrong for every direction
# but 'down' (whose numpad value, 2, happens to equal its own liblcf index,
# masking the bug for that one case). A `--facing up` save resumed under
# genuine RPG_RT.exe under wine this cycle also drew the leader facing down
# rather than up, consistent with the same fallback, though that single
# observation was not isolated cleanly enough (an unrelated input freeze hit
# the same probe) to stand as this cycle's own confirmed behavioral finding
# on its own -- the schema's own pre-existing documentation above is this
# fix's real basis, independent of that wine capture. A future probe relying
# on `--facing up/right/left` should confirm the resulting facing with a
# screenshot rather than assume this bug is the only thing that can go wrong.
LCF_DIRECTION = { 'up' => 0, 'right' => 1, 'down' => 2, 'left' => 3 }.freeze

options = { slot: 1 }
parser = OptionParser.new do |o|
  o.banner = 'Usage: ruby scripts/gen-rpg2k-save.rb [GAME_DIR] [options]'
  o.on('--map ID', Integer, 'map id to place the party on') { |v| options[:map] = v }
  o.on('--at X,Y', 'tile to stand on') { |v| options[:at] = v }
  o.on('--facing DIR', DIRECTIONS.keys, 'down|left|right|up') { |v| options[:facing] = v }
  o.on('--clear-scene', 'drop the running event (113) and pictures (103)') do
    options[:clear_scene] = true
  end
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

map_path = File.join(game_dir, format('Map%04d.lmu', map_id))
unless File.exist?(map_path)
  warn "map #{map_id} has no #{File.basename(map_path)} in #{game_dir}"
  exit 1
end
map = LCF::MapUnit.new(File.open(map_path, 'rb'))

if options[:at]
  x, y = options[:at].split(',').map { |n| Integer(n) }
elsif map_id == from[0]
  x = from[1]
  y = from[2]
else
  # Landing on another map with no tile given: stand in the middle. It is always
  # in bounds, though possibly unwalkable -- which is fine, since the comparison
  # only needs both runtimes on the same tile, and both will draw the hero there.
  x = map.width / 2
  y = map.height / 2
end

hero[HERO_MAP] = map_id
hero[HERO_X] = x
hero[HERO_Y] = y
hero[HERO_DIRECTION] = LCF_DIRECTION.fetch(options[:facing]) if options[:facing]

# Reading a chunk decodes a detached copy, so the edited chunk has to go back in
# before serialising (same as scripts/lcf_save_roundtrip.rb).
save[104] = hero

moved_maps = map_id != from[0]

# Re-centre the saved camera on the new tile. RPG_RT does NOT derive the view
# from the hero when it resumes -- it restores the scroll recorded in chunk 111
# (fields 1/2, in 1/16 pixel; see LCF::Schema::SAVE_MAP_EVENT for how the unit
# was measured). Moving the party without this leaves the old scroll behind, and
# the genuine runtime then draws a completely different part of the map from the
# one our engine draws, which reads as a total rendering mismatch when it is
# only a stale camera.
map_ev = save[MAP_EVENTS] || LCF::Array1D.new('', LCF::Schema::SAVE_DATA[:elements][MAP_EVENTS])
scroll_px = [camera_offset(x * TILE + TILE / 2, SCREEN_W, map.width * TILE),
             camera_offset(y * TILE + TILE / 2, SCREEN_H, map.height * TILE)]
map_ev[SCROLL_X] = scroll_px[0] * LCF::Schema::SCROLL_UNITS_PER_PIXEL
map_ev[SCROLL_Y] = scroll_px[1] * LCF::Schema::SCROLL_UNITS_PER_PIXEL

# Chunk 111 field 11 is a per-event-id position/direction snapshot for
# whichever map the save was captured on -- NOT touched by --clear-scene
# (that only drops the foreground event and shown pictures, chunks 113/103).
# A cross-map move leaves it in place, and a genuine RPG_RT.exe then applies
# it to the NEW map's own events that happen to share an id with the old
# one's snapshot, silently relocating them off their Map####.lmu-authored
# position -- confirmed under wine this cycle (#175): Nepheshel's Map0012
# and Map0016 both number their events 1-4, and moving a Map0012 save onto
# Map0016 left its own event 4 (an item-shop trigger, authored at (14,10))
# unreachable at that spot because chunk 111 still carried Map0012's own
# event-4 position (19,24). There is no scenario where keeping a snapshot
# captured on a DIFFERENT map is desirable, so this is cleared unconditionally
# on any map change (not gated on --clear-scene, whose two chunks are a
# separate, narrower concern -- the mid-execution event and shown pictures).
events_cleared = false
if moved_maps && map_ev.key?(EVENTS)
  map_ev[EVENTS] = LCF::Array2D.new('', LCF::Schema::SAVE_MOVABLE)
  events_cleared = true
end
save[MAP_EVENTS] = map_ev

# Drop the chunks that would replay the scene the save was taken in, leaving the
# party standing on the map with nothing running (see the --clear-scene note in
# the header). Both are optional sections a real save omits when there is no
# event running and no picture shown, so removing them is a state RPG_RT itself
# writes -- unlike an emptied chunk, which is a zero-length event/picture table.
cleared = []
if options[:clear_scene]
  cleared << 'running event (113)' if save.delete(FOREGROUND_EVENT)
  cleared << 'pictures (103)' if save.delete(PICTURES)
end

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
if options[:facing]
  want_dir = LCF_DIRECTION.fetch(options[:facing])
  got_dir = back[104][HERO_DIRECTION]
  unless got_dir == want_dir
    warn "FAILED: wrote facing=#{options[:facing]} (liblcf #{want_dir}) but " \
         "read back #{got_dir} -- this would resume facing the wrong way " \
         '(or the schema default fallback, "down") in any runtime that reads ' \
         'this field, not just the writer bug this check exists to catch'
    exit 1
  end
end
if options[:clear_scene] && (back.key?(FOREGROUND_EVENT) || back.key?(PICTURES))
  warn 'FAILED: --clear-scene left chunk 113/103 in the written save'
  exit 1
end
got_scroll = [back[MAP_EVENTS][SCROLL_X], back[MAP_EVENTS][SCROLL_Y]]
want_scroll = scroll_px.map { |v| v * LCF::Schema::SCROLL_UNITS_PER_PIXEL }
unless got_scroll == want_scroll
  warn "FAILED: wrote scroll #{want_scroll.inspect} but read back #{got_scroll.inspect}"
  exit 1
end
if events_cleared && back[MAP_EVENTS].key?(EVENTS) && back[MAP_EVENTS][EVENTS].any? { |_, v| v }
  warn 'FAILED: a map change left stale per-event position data (chunk 111 ' \
       'field 11) in the written save'
  exit 1
end

puts "#{out}: map #{from[0]} (#{from[1]},#{from[2]}) -> #{map_id} (#{x},#{y})" \
     "#{options[:facing] ? " facing #{options[:facing]}" : ''}" \
     "#{moved_maps ? ' [map changed: old map event execution state (switches/vars/etc) ' \
                      'carries over; per-event positions (chunk 111) cleared]' : ''}" \
     " [camera #{scroll_px[0]},#{scroll_px[1]}px]" \
     "#{cleared.empty? ? '' : " [cleared: #{cleared.join(', ')}]"}"
