#!/usr/bin/env ruby
# encoding: UTF-8
#
# Behaviour oracle for the map layers as they are today: Game::Map's @lower and
# @upper are plain Arrays, and the save packs them through LCF.pack_int16.
#
# This pins the CURRENT (Array-backed) behaviour so that a later storage change
# to std::vector<int16_t> can be checked against
# it. Every expectation is either a value written by hand or a byte string
# computed by hand from the pack rule: each id is masked to its low 16 bits and
# written little-endian. Nothing here asserts the Array identity of the unit's
# chunk 71/72 after a sync, because the unit deliberately gets a copy; the
# oracle pins values and saved bytes only.
#
# Usage: ruby scripts/rpg2k/layer_save_oracle_check.rb   (exits non-zero on any failure)

require 'stringio'

# -- loaders: the same sources logic_check.rb loads, nothing from the scene harness --

lcf_lib = File.expand_path('../../mruby-lcf/mrblib', __dir__)
load File.join(lcf_lib, 'lcf.rb')
load File.join(lcf_lib, 'schema.rb')
load File.join(lcf_lib, 'lcf_file.rb')
load File.join(lcf_lib, 'save_typed.rb')
load File.join(lcf_lib, 'save_typed_accessors.rb')

lib = File.expand_path('../../mruby-rpg2k/mrblib', __dir__)
load File.join(lib, 'game.rb')
load File.join(lib, 'game', 'battle.rb')
load File.join(lib, 'game', 'battle_support.rb') # Game::Map#sync_layers_to_unit lives here

# -- tiny test framework (same shape as scene_check.rb) -----------------------

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

# Stands in for the real LCF::MapUnit a Game::Map wraps. Same shape as the
# FakeMapUnit in scene_check.rb (copied, not required): it answers the fields
# Game::Map.new reads and records #[]= writes.
class FakeMapUnit
  attr_reader :sets
  def initialize(fields)
    @fields = fields
    @sets = {}
  end
  def [](sym) = @fields.fetch(sym)
  def []=(idx, value); @sets[idx] = value; end
end

# A 3x2 map (width 3, height 2). Cell (x, y) is index y * 3 + x.
W = 3
H = 2

# Chosen to cover the pack edges: 1 (plain), -1 (all ones), 32767 (max),
# -32768 (min), 300 (high byte set), 0.
LOWER_START = [1, -1, 32767, -32768, 300, 0].freeze
# -2 (high byte of 0xfffe), 4001 (0x0fa1), 0, 255 (low byte only), -256
# (low byte zero, high byte 0xff), 12345 (0x3039).
UPPER_START = [-2, 4001, 0, 255, -256, 12345].freeze

# Hand-computed packed bytes (16-bit little endian, each value & 0xffff):
#   LOWER_START -> 0100 ffff ff7f 0080 2c01 0000
#   UPPER_START -> feff a10f 0000 ff00 00ff 3930
EXP_LOWER_START_HEX = '0100ffffff7f00802c010000'
EXP_UPPER_START_HEX = 'feffa10f0000ff0000ff3930'

# After the in-range writes below:
#   lower[0] := 32767, lower[4] := -32768      -> [32767, -1, 32767, -32768, -32768, 0]
#   upper[2] := -1                             -> [-2, 4001, -1, 255, -256, 12345]
LOWER_EDITED = [32767, -1, 32767, -32768, -32768, 0].freeze
UPPER_EDITED = [-2, 4001, -1, 255, -256, 12345].freeze
#   LOWER_EDITED -> ff7f ffff ff7f 0080 0080 0000
#   UPPER_EDITED -> feff a10f ffff ff00 00ff 3930
EXP_LOWER_EDITED_HEX = 'ff7fffffff7f008000800000'
EXP_UPPER_EDITED_HEX = 'feffa10fffffff0000ff3930'

def new_map(lower = LOWER_START.dup, upper = UPPER_START.dup)
  unit = FakeMapUnit.new(width: W, height: H, chipset_id: 1,
                         lower_layer: lower, upper_layer: upper, events: {})
  [Game::Map.new(1, unit), unit]
end

def hex(bytes) = bytes.unpack('H*').first

check 'Game::Map#lower/#upper read the Array cell at y * width + x' do
  map, _unit = new_map
  LOWER_START.each_with_index do |v, i|
    eq v, map.lower(i % W, i / W), "lower cell #{i % W},#{i / W}"
  end
  UPPER_START.each_with_index do |v, i|
    eq v, map.upper(i % W, i / W), "upper cell #{i % W},#{i / W}"
  end
end

check 'Game::Map#lower/#upper return nil out of bounds, as Array#[] does past the edge' do
  map, _unit = new_map
  eq nil, map.lower(W, 0), 'x past the right edge'
  eq nil, map.lower(0, H), 'y past the bottom edge'
  eq nil, map.upper(-1, 0), 'negative x'
  eq nil, map.upper(0, -1), 'negative y'
end

check 'the initial layers pack to the hand-computed bytes (no writes yet)' do
  eq EXP_LOWER_START_HEX, hex(LCF.pack_int16(LOWER_START)), 'lower'
  eq EXP_UPPER_START_HEX, hex(LCF.pack_int16(UPPER_START)), 'upper'
end

check 'LCF.pack_int16 masks each value to its low 16 bits, little-endian' do
  # 65537 & 0xffff = 1, -65537 & 0xffff = 0xffff, 65536 & 0xffff = 0.
  eq '0100ffff0000', hex(LCF.pack_int16([65537, -65537, 65536])), 'out-of-int16 values wrap'
  eq '', hex(LCF.pack_int16([])), 'an empty layer packs to no bytes'
end

check 'Game::Map#set_lower/#set_upper write in-range ids, read back, and bump the revision' do
  map, _unit = new_map
  rev = map.revision
  map.set_lower(0, 0, 32767)
  eq 32767, map.lower(0, 0), 'set_lower reads back at max int16'
  rev_after_lower = map.revision
  ok rev_after_lower > rev, 'set_lower bumps the cache-invalidation revision'
  map.set_lower(1, 1, -32768)
  eq(-32768, map.lower(1, 1), 'set_lower reads back at min int16')
  eq(-1, map.lower(1, 0), 'an untouched neighbour keeps its id')
  map.set_upper(2, 0, -1)
  eq(-1, map.upper(2, 0), 'set_upper reads back at -1')
  ok map.revision > rev_after_lower, 'set_upper bumps the revision too'
end

check 'an edited cell is the only one that changes on read' do
  map, _unit = new_map
  map.set_lower(0, 0, 32767)
  map.set_lower(1, 1, -32768)
  LOWER_EDITED.each_with_index do |v, i|
    eq v, map.lower(i % W, i / W), "lower cell #{i % W},#{i / W} after edits"
  end
end

check '#sync_layers_to_unit pushes the edited layers into chunks 71 and 72' do
  map, unit = new_map
  map.set_lower(0, 0, 32767)
  map.set_lower(1, 1, -32768)
  map.set_upper(2, 0, -1)
  map.sync_layers_to_unit
  eq LOWER_EDITED, unit.sets[71], 'chunk 71 holds the whole edited lower layer'
  eq UPPER_EDITED, unit.sets[72], 'chunk 72 holds the whole edited upper layer'
  eq nil, unit.sets[70], 'no other chunk is written by the sync'
end

check 'the saved chunk 71/72 bytes are the packed edited layers (via pack_int16 and LCF.encode)' do
  map, unit = new_map
  map.set_lower(0, 0, 32767)
  map.set_lower(1, 1, -32768)
  map.set_upper(2, 0, -1)
  map.sync_layers_to_unit
  eq EXP_LOWER_EDITED_HEX, hex(LCF.pack_int16(unit.sets[71])), 'chunk 71 packed bytes'
  eq EXP_UPPER_EDITED_HEX, hex(LCF.pack_int16(unit.sets[72])), 'chunk 72 packed bytes'
  eq EXP_LOWER_EDITED_HEX, hex(LCF.encode(unit.sets[71], :int16_array)), 'encode dispatches to pack_int16 for chunk 71'
  eq EXP_UPPER_EDITED_HEX, hex(LCF.encode(unit.sets[72], :int16_array)), 'encode dispatches to pack_int16 for chunk 72'
end

check 'the saved bytes read back to the same values (save round trip)' do
  map, unit = new_map
  map.set_lower(0, 0, 32767)
  map.set_lower(1, 1, -32768)
  map.set_upper(2, 0, -1)
  map.sync_layers_to_unit
  lower_bytes = LCF.pack_int16(unit.sets[71])
  upper_bytes = LCF.pack_int16(unit.sets[72])
  eq LOWER_EDITED, LCF.to_rb(lower_bytes, type: :int16_array), 'chunk 71 reads back'
  eq UPPER_EDITED, LCF.to_rb(upper_bytes, type: :int16_array), 'chunk 72 reads back'
end

if $failures.zero?
  puts "rpg2k layer save oracle: all #{$checks} checks passed"
  exit 0
else
  warn "rpg2k layer save oracle: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
