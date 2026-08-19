#!/usr/bin/env ruby
# encoding: UTF-8
#
# Bidirectional converter between RPG Maker 2000/2003's LCF binary project
# files (.ldb database, .lmu map unit, .lsd save) and a human-editable YAML
# text form, schema-checked against mruby-lcf/mrblib/schema.rb in both
# directions -- this is the "text-based parameter editor" half of the debug
# tooling in mruby-rpg2k/mrblib/scene/ (the Map viewer, see map_viewer.rb, is
# the other half: some data is easier painted than typed).
#
# The binary <-> Ruby-tree codec is not reimplemented here -- it is
# mruby-lcf/mrblib/lcf.rb's own LCF.to_rb / Array1D#to_lcf / LCF.encode, the
# same machinery that already round-trips real .lsd saves byte-exact (see
# scripts/lcf_save_roundtrip.rb). This script only adds the schema-driven
# layer between that Ruby tree and text: field names instead of raw chunk
# ids, and a validation pass that reports every problem in an edited file
# before attempting to encode it, rather than a raw exception (or a silently
# wrong write) from the encoder itself.
#
# Usage:
#   ruby scripts/lcf_text_convert.rb to_text   IN.ldb|lmu|lmt|lsd  OUT.yml
#   ruby scripts/lcf_text_convert.rb to_binary IN.yml              OUT.ldb|lmu|lsd
#   ruby scripts/lcf_text_convert.rb check     IN.yml
#
# `to_text` reads the binary file and its type is taken from its extension.
# The YAML it writes carries its own `type:` field (one of database/map_unit/
# save_data/map_tree), so `to_binary`/`check` do not need to guess from a
# filename -- OUT's extension only picks the output path, not the schema.
#
# `.lmt` (the map tree) is text-exportable but not yet writable: its file is a
# multi-section format (map-properties table + tree order + party start
# position) and mruby-lcf's own File#to_lcf does not implement serialising
# that shape yet (see LCF::File#to_lcf's own comment in lcf.rb) -- a
# `to_binary`/`check` on a map_tree document reports that plainly rather than
# attempting something unproven.
#
# Exits non-zero on any schema violation (`check`/`to_binary`) or read/write
# failure, printing every problem found, not just the first.

require 'stringio'
require 'yaml'

module LCF
  # uni-algo stand-ins, matching every other CRuby-hosted LCF script in this
  # repo (e.g. scripts/lcf_save_roundtrip.rb) -- see that file's own comment
  # for why both directions transcode through Windows-31J rather than the
  # native uni-algo encoder this build would otherwise use.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end

  def utf8_to_cp932(s)
    s.encode('Windows-31J', invalid: :replace, undef: :replace)
     .force_encoding('BINARY')
  end
  module_function :cp932_to_utf8, :utf8_to_cp932

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')

# type name (as it appears in the YAML `type:` field) -> [LCF file class, the
# file extensions `to_text` recognises for it].
FILE_TYPES = {
  'database' => [LCF::Database, %w[.ldb]],
  'map_unit' => [LCF::MapUnit, %w[.lmu]],
  'save_data' => [LCF::SaveData, %w[.lsd]],
  'map_tree' => [LCF::MapTree, %w[.lmt]],
}.freeze

def file_class_for_ext(ext)
  FILE_TYPES.each { |name, (klass, exts)| return [name, klass] if exts.include?(ext) }
  nil
end

# ---- binary -> text ---------------------------------------------------------

# One Array1D/Array2D chunk-table walk shared by every record type: only
# chunks actually present in the file are emitted (Array1D#key?), so an
# absent-vs-empty-vs-default field stays distinguishable after a round trip
# the same way it is at runtime (see mruby-rpg2k's own commentary on this,
# e.g. Scene::DebugMenu#max_id).
def array1d_to_text(obj, schema)
  h = {}
  schema[:elements].each do |idx, field|
    next unless obj.key?(idx)
    h[field[:name].to_s] = value_to_text(obj[idx], field)
  end
  h
end

def value_to_text(value, field)
  case field[:type]
  when :Array1D
    array1d_to_text(value, field)
  when :Array2D
    h = {}
    value.each { |id, row| h[id] = array1d_to_text(row, field) }
    h
  when :event
    value.map { |c| { 'code' => c.code, 'indent' => c.indent, 'string' => c.string,
                       'parameters' => c.parameters } }
  when :move_commands
    value.map do |c|
      { 'command_id' => c.command_id, 'parameter_string' => c.parameter_string,
        'parameter_a' => c.parameter_a, 'parameter_b' => c.parameter_b,
        'parameter_c' => c.parameter_c }
    end
  when :int16_array
    value.is_a?(Hash) ? value.each_with_object({}) { |(k, v), h| h[k.to_s] = v } : value
  when :Tree
    { 'selected_id' => value.selected_id, 'maps' => value.maps }
  else
    value
  end
end

# A .lmt's root is LCF::Sections, not a single Array1D -- its own schema is an
# Array of per-section schemas (LCF::Schema::MAP_TREE), each read
# independently (see LCF.read_section). Walk that shape instead.
def sections_to_text(file)
  h = {}
  file.schema.each do |s|
    section = file.send(s[:name])
    h[s[:name].to_s] =
      case s[:type]
      when :Array2D, :Array1D then array1d_or_2d_to_text(section, s)
      when :Tree then { 'selected_id' => section.selected_id, 'maps' => section.maps }
      else raise "unhandled map-tree section type: #{s[:type]}"
      end
  end
  h
end

def array1d_or_2d_to_text(obj, schema)
  return array1d_to_text(obj, schema) if schema[:type] == :Array1D
  h = {}
  obj.each { |id, row| h[id] = array1d_to_text(row, schema) }
  h
end

def to_text(in_path, out_path)
  ext = File.extname(in_path).downcase
  type_name, klass = file_class_for_ext(ext)
  unless klass
    warn "unrecognised extension #{ext.inspect} -- expected one of " \
         "#{FILE_TYPES.values.flat_map(&:last).join(', ')}"
    exit 1
  end
  file = klass.new(StringIO.new(File.binread(in_path)))
  data = type_name == 'map_tree' ? sections_to_text(file) : array1d_to_text(file, file.schema)
  doc = { 'type' => type_name, 'data' => data }
  File.write(out_path, YAML.dump(doc))
  puts "wrote #{out_path} (#{type_name}, from #{in_path})"
rescue StandardError => e
  warn "failed to read #{in_path}: #{e.class}: #{e.message}"
  exit 1
end

# ---- schema validation -------------------------------------------------------

# Every problem found, each as one "path: message" string -- collected rather
# than raised on the first one, so a single run reports everything wrong with
# an edited file instead of a fix-one-rerun loop.
def validate_array1d(value, schema, path, errors)
  unless value.is_a?(Hash)
    errors << "#{path}: expected a mapping of field name => value, got #{value.class}"
    return
  end
  by_name = {}
  schema[:elements].each { |idx, f| by_name[f[:name].to_s] = [idx, f] }
  value.each do |name, v|
    entry = by_name[name.to_s]
    unless entry
      errors << "#{path}.#{name}: unknown field (not in the #{schema[:name]} schema)"
      next
    end
    validate_value(v, entry[1], "#{path}.#{name}", errors)
  end
end

def validate_value(value, field, path, errors)
  case field[:type]
  when :int, :uint8
    errors << "#{path}: expected an integer, got #{value.class}" unless value.is_a?(Integer)
    errors << "#{path}: #{value} is out of range for uint8 (0..255)" \
      if field[:type] == :uint8 && value.is_a?(Integer) && !(0..255).cover?(value)
  when :bool
    errors << "#{path}: expected true/false, got #{value.class}" \
      unless [true, false].include?(value)
  when :double
    errors << "#{path}: expected a number, got #{value.class}" unless value.is_a?(Numeric)
  when :string
    errors << "#{path}: expected a string, got #{value.class}" unless value.is_a?(String)
  when :int8_array, :int16_array, :int32_array
    validate_int_array(value, path, errors)
  when :bool_array
    unless value.is_a?(Array) && value.all? { |v| [true, false].include?(v) }
      errors << "#{path}: expected a list of true/false, got #{value.inspect}"
    end
  when :Array1D
    validate_array1d(value, field, path, errors)
  when :Array2D
    unless value.is_a?(Hash)
      errors << "#{path}: expected a mapping of id => row, got #{value.class}"
    else
      value.each { |id, row| validate_array1d(row, field, "#{path}[#{id}]", errors) }
    end
  when :event
    validate_event_commands(value, path, errors)
  when :move_commands
    validate_move_commands(value, path, errors)
  when :Tree
    errors << "#{path}: expected a mapping with selected_id/maps" unless value.is_a?(Hash)
  end
end

def validate_int_array(value, path, errors)
  unless value.is_a?(Array)
    return errors << "#{path}: expected a list of integers, got #{value.class}"
  end
  value.each_with_index do |v, i|
    errors << "#{path}[#{i}]: expected an integer, got #{v.class}" unless v.is_a?(Integer)
  end
end

def validate_event_commands(value, path, errors)
  unless value.is_a?(Array)
    return errors << "#{path}: expected a list of event commands, got #{value.class}"
  end
  value.each_with_index do |c, i|
    row = "#{path}[#{i}]"
    unless c.is_a?(Hash)
      errors << "#{row}: expected a mapping with code/indent/string/parameters, got #{c.class}"
      next
    end
    %w[code indent].each { |k| errors << "#{row}.#{k}: missing" unless c[k].is_a?(Integer) }
    errors << "#{row}.string: missing or not a string" unless c['string'].is_a?(String)
    errors << "#{row}.parameters: missing or not a list of integers" \
      unless c['parameters'].is_a?(Array) && c['parameters'].all? { |p| p.is_a?(Integer) }
  end
end

def validate_move_commands(value, path, errors)
  unless value.is_a?(Array)
    return errors << "#{path}: expected a list of move commands, got #{value.class}"
  end
  value.each_with_index do |c, i|
    row = "#{path}[#{i}]"
    unless c.is_a?(Hash)
      errors << "#{row}: expected a mapping with command_id/parameter_*, got #{c.class}"
      next
    end
    errors << "#{row}.command_id: missing" unless c['command_id'].is_a?(Integer)
  end
end

def validate_document(doc)
  errors = []
  unless doc.is_a?(Hash) && doc['type'] && doc['data']
    errors << "document: expected a mapping with 'type' and 'data' (as written by `to_text`)"
    return errors
  end
  klass, = FILE_TYPES[doc['type']]
  unless klass
    errors << "document.type: #{doc['type'].inspect} is not one of " \
              "#{FILE_TYPES.keys.join(', ')}"
    return errors
  end
  if doc['type'] == 'map_tree'
    errors << 'document: map_tree is text-exportable but not yet writable back to binary ' \
               '(LCF::File#to_lcf does not implement the multi-section .lmt format yet)'
    return errors
  end
  validate_array1d(doc['data'], klass.new.schema, 'data', errors)
  errors
end

# ---- text -> binary ----------------------------------------------------------

def build_array1d(hash, schema)
  obj = LCF::Array1D.new('', schema)
  by_name = {}
  schema[:elements].each { |idx, f| by_name[f[:name].to_s] = [idx, f] }
  hash.each do |name, value|
    idx, field = by_name[name.to_s]
    obj[idx] = build_value(value, field)
  end
  obj
end

def build_value(value, field)
  case field[:type]
  when :Array1D
    build_array1d(value, field)
  when :Array2D
    obj = LCF::Array2D.new('', field)
    value.each { |id, row| obj[id.to_i] = build_array1d(row, field) }
    obj
  when :event
    value.map { |c| LCF::EventCommand.new(c['code'], c['indent'], c['string'],
                                           c['parameters']) }
  when :move_commands
    value.map do |c|
      LCF::MoveCommand.new(c['command_id'], c['parameter_string'],
                            c['parameter_a'], c['parameter_b'], c['parameter_c'])
    end
  else
    value
  end
end

def to_binary(in_path, out_path)
  doc = YAML.safe_load(File.read(in_path), permitted_classes: [Symbol])
  errors = validate_document(doc)
  unless errors.empty?
    warn "#{in_path}: #{errors.size} schema problem(s):"
    errors.each { |e| warn "  #{e}" }
    exit 1
  end
  klass, = FILE_TYPES[doc['type']]
  file = klass.new
  by_name = {}
  file.schema[:elements].each { |idx, f| by_name[f[:name].to_s] = [idx, f] }
  doc['data'].each do |name, value|
    idx, field = by_name[name.to_s]
    file[idx] = build_value(value, field)
  end
  file.save_to(out_path)
  puts "wrote #{out_path} (#{doc['type']}, from #{in_path})"
rescue StandardError => e
  warn "failed to write #{out_path}: #{e.class}: #{e.message}"
  exit 1
end

def check(in_path)
  doc = YAML.safe_load(File.read(in_path), permitted_classes: [Symbol])
  errors = validate_document(doc)
  if errors.empty?
    puts "#{in_path}: OK, matches the #{doc['type']} schema"
    exit 0
  else
    warn "#{in_path}: #{errors.size} schema problem(s):"
    errors.each { |e| warn "  #{e}" }
    exit 1
  end
end

# ---- CLI ----------------------------------------------------------------------

USAGE = <<~USAGE
  Usage:
    ruby scripts/lcf_text_convert.rb to_text   IN.ldb|lmu|lmt|lsd  OUT.yml
    ruby scripts/lcf_text_convert.rb to_binary IN.yml              OUT.ldb|lmu|lsd
    ruby scripts/lcf_text_convert.rb check     IN.yml
USAGE

case ARGV[0]
when 'to_text'
  in_path, out_path = ARGV[1], ARGV[2]
  (warn USAGE; exit 1) unless in_path && out_path
  to_text(in_path, out_path)
when 'to_binary'
  in_path, out_path = ARGV[1], ARGV[2]
  (warn USAGE; exit 1) unless in_path && out_path
  to_binary(in_path, out_path)
when 'check'
  in_path = ARGV[1]
  (warn USAGE; exit 1) unless in_path
  check(in_path)
else
  warn USAGE
  exit 1
end
