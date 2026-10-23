#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side checks for the typed, checked save read path.
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
#      read succeeds, and the frames read as nil), as it always was;
#   6. the typed writers: every field of every table, set through
#      its generated writer, writes the same bytes as `rec[id] = value` (the schema
#      encoder), a populated save read back through the readers and written out
#      through the writers reproduces its bytes, and the generated writer file has no
#      String literal (field names are Symbols, so bc2cpp's static-dispatch proof holds).
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
%w[lcf.rb schema.rb lcf_file.rb save_typed.rb save_typed_accessors.rb
   save_typed_put.rb save_typed_setters.rb].each do |f|
  load File.join(mrblib, f)
end

# The generator's table walk matches nested tables to their SAVE_* constants by identity,
# which LCF.elements_of's in-place caching (any read of a save) breaks: walk it first.
load File.expand_path('../mruby-lcf/gen_save_typed_accessors.rb', __dir__)
TABLES = GenSaveTyped.tables

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
  generated = GenSaveTyped.generate
  current = File.read(File.join(mrblib, 'save_typed_accessors.rb'))
  ok generated == current, 'mruby-lcf/mrblib/save_typed_accessors.rb is stale: ' \
                           'run ruby mruby-lcf/gen_save_typed_accessors.rb'
  ok GenSaveTyped.generate_setters == File.read(File.join(mrblib, 'save_typed_setters.rb')),
     'mruby-lcf/mrblib/save_typed_setters.rb is stale: run ruby mruby-lcf/gen_save_typed_accessors.rb'
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

# -- the typed writers -----------------------------------------------------

# A value of the Ruby class each schema type declares, distinct per depth.
def sample_value(field, depth = 0)
  case field[:type]
  when :int then 12_345 - depth
  when :uint8 then 200
  when :bool then true
  when :double then 41_000.5
  when :string then 'Sample'
  when :int8_array then [1, 2, 3, 250]
  when :bool_array then [true, false, true]
  when :int16_array then field[:order] ? field[:order].map.with_index { |_, i| i - 1 } : [1, -2, 300]
  when :int32_array then [1, -2, 70_000]
  when :event then [LCF::EventCommand.new(10110, 0, 'hi', [0, 1, 2]), LCF::EventCommand.new(0, 0, '', [])]
  when :move_commands
    [{ command_id: 1 }, { command_id: 32, parameter_a: 3 }, { command_id: 34, parameter_string: 'x', parameter_a: 1 }]
  when :Array1D
    rec = LCF::Array1D.new('', field)
    LCF.elements_of(field).each { |id, f| rec[id] = sample_value(f, depth + 1) }
    rec
  when :Array2D
    tbl = LCF::Array2D.new('', field)
    [1, 2, 50].each do |row|
      rec = LCF::Array1D.new('', field)
      LCF.elements_of(field).each { |id, f| rec[id] = sample_value(f, depth + 1) }
      tbl[row] = rec
    end
    tbl
  else raise "no sample for #{field[:type]}"
  end
end

def table_schema(const)
  return LCF::Schema::SAVE_DATA if const == :SAVE_DATA
  { elements: GenSaveTyped.resolve(LCF::Schema.const_get(const)) }
end

check 'every field of every table: the typed writer writes the same bytes as the schema encoder' do
  order, fields = TABLES
  kinds = {}
  count = 0
  order.each do |const|
    cls = LCF::SaveTyped.const_get(GenSaveTyped.class_name(const))
    fields[const].each do |id, f, _child|
      v = sample_value(f)
      direct = LCF::Array1D.new('', table_schema(const))
      direct[id] = v
      rec = LCF::Array1D.new('', table_schema(const))
      cls.new(rec, 'T').send("save_#{f[:name]}=", v)
      eq direct.to_lcf, rec.to_lcf, "#{const} field #{id} (#{f[:name]}, #{f[:type]})"
      kinds[f[:type]] = true
      count += 1
    end
  end
  ok count >= 250, "covers every field (#{count})"
  eq %i[Array1D Array2D bool bool_array double event int int16_array int32_array int8_array move_commands string uint8],
     kinds.keys.sort_by(&:to_s), 'every field kind in the save schema'
end

check 'a populated save read through the readers and written through the writers keeps its bytes' do
  full = LCF::SaveData.new
  LCF::Schema::SAVE_DATA[:elements].each { |id, f| full[id] = sample_value(f) }
  bytes = full.to_lcf
  src = read_back(bytes).typed
  dst = LCF::SaveData.new
  out = LCF::SaveTyped::Save.new(dst.instance_variable_get(:@root), 'Save')
  %w[title system screen pictures hero boat ship airship actors inventory targets map_events
     foreground_event common_events lsd_ext].each do |name|
    out.send("save_#{name}=", src.send("save_#{name}"))
  end
  eq bytes, dst.to_lcf, 'bytes after read -> write'
end

check 'a writer refuses a value of the wrong class, naming the field, and writes nothing' do
  rec = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
  hero = LCF::SaveTyped::Movable.new(rec, 'Save.hero')
  {
    'save_map_id=' => 'seven', 'save_through=' => 1, 'save_charset_name=' => 5,
    'save_x=' => 1.5, 'save_event_id=' => true,
  }.each do |m, v|
    next unless hero.respond_to?(m)
    err = (begin; hero.send(m, v); rescue LCF::SaveTypeError => e; e; end)
    ok err, "#{m} refused #{v.inspect}"
    ok err.message.start_with?('Save.hero.'), "message names the field (#{err.message})"
  end
  eq '', rec.to_lcf(false), 'nothing was written'
end

check 'a writer accepts an Integer for a double, a typed record for a table, and nil to drop a chunk' do
  save = LCF::SaveData.new
  typed = save.typed
  title = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_TITLE })
  typed.save_title = title
  typed.save_title.save_timestamp = 3
  eq 3.0, typed.save_title.save_timestamp
  typed.save_title.save_hero_name = 'Hero'
  eq 'Hero', save.typed.save_title.save_hero_name
  direct = LCF::SaveData.new
  d = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_TITLE })
  d[1] = 3
  d[11] = 'Hero'
  direct[100] = d
  eq direct.to_lcf, save.to_lcf, 'bytes match the encoder'
  typed.save_title.save_hero_name = nil
  ok !save.typed.save_title.rec.key?(11), 'nil drops the chunk'
  ok save.typed.save_title.save_hero_name.nil?, 'and the field reads as absent (no schema default)'
end

check 'a named 16-bit array (a Hash on read) is written back in schema order' do
  # No save table names an int16_array's members, so use a one-field table that does.
  schema = { elements: { 1 => { name: :stats, type: :int16_array, order: %i[hp sp] } } }
  rec = LCF::Array1D.new('', schema)
  klass = Class.new(LCF::SaveTyped::Record) { def save_stats=(v); save_put 1, v end }
  klass.new(rec, 'T').save_stats = { hp: 7, sp: -3 }
  direct = LCF::Array1D.new('', schema)
  direct[1] = [7, -3]
  eq direct.to_lcf, rec.to_lcf, 'schema order'
  eq({ hp: 7, sp: -3 }, rec[1], 'reads back as the same Hash')
end

check 'the generated writers use Symbol-only dispatch: no String literal, no dynamic send' do
  src = File.read(File.join(mrblib, 'save_typed_setters.rb')).lines.reject { |l| l.start_with?('#') }.join
  ok !src.match?(/["']/), 'a String literal in save_typed_setters.rb'
  ok !src.match?(/\b(send|public_send|__send__|define_method|instance_variable_set)\b/), 'dynamic dispatch'
end

puts
if $failures.zero?
  puts "lcf save typed check: #{$checks} checks passed"
  exit 0
else
  warn "lcf save typed check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
