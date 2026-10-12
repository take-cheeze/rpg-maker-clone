#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side checks for the typed, checked save read path (docs/adr/0400).
#
# LCF::SaveData checks every field of a save against its schema type when the
# save is read, and mruby-lcf/mrblib/save_typed_accessors.rb (generated) reads
# each one as its declared class. Under CRuby this checks:
#
#   1. the generated accessors are up to date with mrblib/schema.rb;
#   2. a valid save reads through the typed path, and its values come out typed;
#   3. a save written and read back reproduces its bytes exactly (the on-disk
#      format is unchanged);
#   4. a field whose bytes do not decode as its declared type raises
#      LCF::SaveTypeError naming the field, and a wrong class is refused too;
#   5. a malformed chunk 113/114 execution-state stack is still tolerated (the
#      read succeeds, and the frames read as nil), as it always was.
#
# Usage: ruby scripts/lcf_save_typed_check.rb   (exits non-zero on failure)

require 'stringio'

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

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
%w[lcf.rb schema.rb lcf_file.rb save_typed.rb save_typed_accessors.rb].each do |f|
  load File.join(mrblib, f)
end

$checks = 0
$failures = 0

def check(name)
  $checks += 1
  yield
  puts "  ok   #{name}"
rescue StandardError => e
  $failures += 1
  warn "  FAIL #{name}: #{e.class}: #{e.message}"
end

def ok(cond, msg = 'expected truthy')
  raise msg unless cond
end

def eq(expected, actual, msg = nil)
  raise "#{msg || 'values differ'}: expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def capture_stderr
  old = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = old
end

# A valid save, built through the schema the way the writer builds one.
def sample_save
  save = LCF::SaveData.new
  title = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_TITLE })
  title[1] = 41_000.5
  title[11] = 'Hero'
  title[13] = 7
  save[100] = title
  system = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_SYSTEM })
  system[11] = 1234
  system[131] = 3
  save[101] = system
  hero = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
  hero[11] = 5
  hero[12] = 3
  hero[13] = 4
  hero[51] = true
  hero[73] = 'Charset'
  save[104] = hero
  save
end

def read_back(bytes)
  LCF::SaveData.new(StringIO.new(bytes))
end

# A raw chunk stream (id, payload) pairs, ending with the id-0 terminator.
def chunk_stream(pairs)
  out = String.new.b
  pairs.each { |id, payload| out << LCF.write_ber(id) << LCF.write_ber(payload.bytesize) << payload.b }
  out << LCF.write_ber(0)
end

check 'the generated accessors are up to date with mrblib/schema.rb' do
  load File.expand_path('../mruby-lcf/gen_save_typed_accessors.rb', __dir__)
  generated = GenSaveTyped.generate
  current = File.read(File.join(mrblib, 'save_typed_accessors.rb'))
  ok generated == current, 'mruby-lcf/mrblib/save_typed_accessors.rb is stale: ' \
                           'run ruby mruby-lcf/gen_save_typed_accessors.rb'
end

check 'a valid save reads through the typed path, with each value as its declared class' do
  bytes = sample_save.to_lcf
  typed = read_back(bytes).typed
  ok typed.save_title.is_a?(LCF::SaveTyped::Title), 'a nested table is its own typed record'
  eq 'Hero', typed.save_title.save_hero_name, 'a string field'
  eq 7, typed.save_title.save_hero_hp, 'an int field'
  eq 41_000.5, typed.save_title.save_timestamp, 'a double field'
  eq 5, typed.save_hero.save_map_id, 'an int field in a nested table'
  eq true, typed.save_hero.save_through, 'a bool field'
  eq 'Charset', typed.save_hero.save_charset_name, 'a string field in a nested table'
  eq 1234, typed.save_system.save_frame_count, 'a system int field'
  eq 0, typed.save_title.save_face1_index, 'an absent field reads its schema default'
  ok typed.save_hero.save_direction.nil?, 'an absent field with no default reads nil'
  ok typed.save_boat.nil?, 'an absent table reads as nothing, not garbage'
  ok read_back(bytes).typed.check!.is_a?(LCF::SaveTyped::Save), 'the whole tree checks'
end

check 'a save read and written back reproduces its bytes exactly' do
  bytes = sample_save.to_lcf
  eq bytes, read_back(bytes).to_lcf, 'round trip differs'
  eq bytes, read_back(read_back(bytes).to_lcf).to_lcf, 'second round trip differs'
end

check 'a bool field whose bytes do not decode raises, naming the field' do
  save = sample_save
  save[104] = chunk_stream([[51, "\x01\x00".b]])
  err = nil
  begin
    read_back(save.to_lcf)
  rescue LCF::SaveTypeError => e
    err = e
  end
  ok err, 'a SaveTypeError was raised'
  ok err.message.start_with?('Save.hero.through:'), "the message names the field (got #{err && err.message.inspect})"
  ok err.message.include?('invalid bool size: 2'), "the message gives the decode failure (got #{err.message.inspect})"
end

check 'a value of the wrong class is refused by the typed read' do
  rec = Object.new
  def rec.[](_id) 'not an integer' end
  err = nil
  begin
    LCF::SaveTyped.read(rec, 11, :int, 'Save.hero.map_id')
  rescue LCF::SaveTypeError => e
    err = e
  end
  ok err, 'a SaveTypeError was raised'
  eq 'Save.hero.map_id: expected int, got String', err.message, 'the message'
end

check 'the type vocabulary maps each schema type to its declared class' do
  ok LCF::SaveTyped.fits?(:int, 3), 'int is Integer'
  ok !LCF::SaveTyped.fits?(:int, true), 'int refuses a bool'
  ok LCF::SaveTyped.fits?(:bool, false), 'bool is true or false'
  ok !LCF::SaveTyped.fits?(:bool, nil), 'bool refuses nil'
  ok LCF::SaveTyped.fits?(:double, 1.5), 'double is Float'
  ok LCF::SaveTyped.fits?(:string, 'a'), 'string is String'
  ok LCF::SaveTyped.fits?(:int8_array, [1, 2]), 'int8_array is an Array'
  ok LCF::SaveTyped.fits?(:int16_array, { a: 1 }), 'a named int16_array is a Hash'
  ok !LCF::SaveTyped.fits?(:Array1D, 'x'), 'Array1D refuses a raw String'
end

check 'a malformed chunk 113 execution-state stack is tolerated by the read itself' do
  save = sample_save
  foreground = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_FOREGROUND_EVENT })
  foreground[1] = LCF::Array1D.new("\x01\x01\x01\x00".b, { elements: LCF::Schema::SAVE_EVENT_EXEC_STATE })
  save[113] = foreground
  read = read_back(save.to_lcf)
  ok read, 'the save reads, the stack is not checked on read'
  # The frames themselves do not decode: that is raised here, and
  # Game::State.read_event_exec_frames turns it into "nothing to restore".
  err = nil
  begin
    read.typed.save_foreground_event.frames
  rescue LCF::SaveTypeError => e
    err = e
  end
  ok err && err.message.include?('stack'), "the frames raise, naming the stack (got #{err && err.message.inspect})"
end

check 'the typed frame has the shape restore_call_stack reads' do
  stack = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_EVENT_EXEC_FRAME })
  frame = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_EVENT_EXEC_FRAME })
  frame[2] = []
  frame[11] = 4
  frame[12] = 9
  frame[13] = true
  stack[1] = frame
  state = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_EVENT_EXEC_STATE })
  state[1] = stack
  common = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_COMMON_EVENT })
  common[1] = state
  save = LCF::SaveData.new
  rows = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_COMMON_EVENT })
  rows[3] = common
  save[114] = rows
  entry = LCF::SaveTyped::CommonEvent.new(read_back(save.to_lcf).typed.save_common_events[3], 'Save.common_events[3]')
  frames = entry.save_execution_state.frames
  eq 1, frames.size, 'one frame'
  eq({ commands: [], current_command: 4, event_id: 9, triggered_by_decision_key: true }, frames[0], 'frame shape')
end

puts
if $failures.zero?
  puts "lcf save typed check: #{$checks} checks passed"
  exit 0
else
  warn "lcf save typed check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
