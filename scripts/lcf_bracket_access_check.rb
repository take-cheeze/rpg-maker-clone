#!/usr/bin/env ruby
# encoding: UTF-8
#
# Regression check for LCF's `[]`-only field access (docs/adr/0213).
#
# LCF::Array1D, LCF::Sections and LCF::File used to answer `row.hp_max`,
# `tree.initial` and `db.actor` through method_missing, and
# `row.respond_to?(:hp_max)` through respond_to_missing?. Both hooks are gone:
# a field is read with `row[:hp_max]`, and "does this record's schema declare
# the field" is `row.field?(:hp_max)` / `LCF.field?(obj, :hp_max)`. This
# check pins that down in two parts.
#
#   1. Structure (always runs): none of the LCF record, section or file
#      classes defines method_missing / respond_to_missing? again, none of
#      them answers any schema field name as a method, a dotted read raises
#      NoMethodError, and #field? / LCF.field? give the answers the old
#      respond_to? guard gave.
#   2. Real data (needs a downloaded test bed): for a sample of real records
#      from data/Nepheshel206beta (or the game dirs given), every schema field
#      read through `[]` returns the very value the removed dotted access
#      returned. The old access was `self[sym2idx[name]]` (the schema's
#      name -> chunk id table, last declaration wins); it is rebuilt here from
#      the schema itself, independently of Array1D's own private lookup.
#
# Usage:
#   ruby scripts/lcf_bracket_access_check.rb [GAME_DIR ...]
# With no arguments it checks both editions under data/Nepheshel206beta; when
# that is not downloaded, the real-data part is reported and skipped (exit 0).

require 'stringio'
require 'ostruct'

module LCF
  # uni-algo stand-in, as in scripts/lcf_testbed_check.rb.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{fffd}")
  end
  module_function :cp932_to_utf8

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

ROOT = File.expand_path('..', __dir__)
mrblib = File.join(ROOT, 'mruby-lcf', 'mrblib')
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')
load File.join(mrblib, 'lcf_file.rb')

$failures = 0
$checks = 0

def fail!(msg)
  $failures += 1
  warn "  FAIL #{msg}"
end

def check(cond, msg)
  $checks += 1
  fail!(msg) unless cond
end

# Every field and section name any schema declares.
def schema_names
  names = []
  walk = lambda do |e|
    case e
    when Proc then walk.call(e.call)
    when Array then e.each { |x| walk.call(x) }
    when Hash
      names << e[:name] if e[:name].is_a?(Symbol) && e.key?(:type)
      e.each { |k, v| walk.call(v) if k != :default && (v.is_a?(Hash) || v.is_a?(Array) || v.is_a?(Proc)) }
    end
  end
  LCF::Schema.constants.each do |c|
    v = LCF::Schema.const_get(c)
    walk.call(v) if v.is_a?(Hash) || v.is_a?(Array) || v.is_a?(Proc)
  end
  names.uniq
end

LCF_CLASSES = [LCF::Array1D, LCF::Array2D, LCF::Sections, LCF::File, LCF::Database,
               LCF::MapTree, LCF::MapUnit, LCF::SaveData].freeze
NAMES = schema_names

# -- 1. structure ---------------------------------------------------------------

LCF_CLASSES.each do |klass|
  own = klass.instance_methods(false) + klass.private_instance_methods(false)
  %i[method_missing respond_to_missing?].each do |hook|
    check !own.include?(hook), "#{klass} defines #{hook} again"
  end
  answered = NAMES.select { |n| klass.public_method_defined?(n) || klass.protected_method_defined?(n) }
  check answered.empty?, "#{klass} answers schema field name(s) as methods: #{answered.first(10).inspect}"
end

movable = { elements: LCF::Schema::SAVE_MOVABLE }
row = LCF::Array1D.new('', movable)
row[:x] = 5
check row[:x] == 5, 'row[:x] reads the field back'
check row.field?(:x), 'field? is true for a field the schema declares and the record carries'
check row.field?(:y), 'field? is true for a declared field that is absent from the record'
check !row.key?(:y), '...which key? (present in the file) still reports absent'
check !row.field?(:no_such_field), 'field? is false for a name the schema does not declare'
check !LCF::Array1D.new('', nil).field?(:x), 'field? is false for a record built without a schema'
check !row.respond_to?(:x), 'a record no longer responds to a field name'
begin
  row.x
  fail!('a dotted field read no longer works, it must raise')
rescue NoMethodError
  $checks += 1
end

check LCF.field?(row, :x), 'LCF.field? asks an LCF record its schema'
check !LCF.field?(row, :no_such_field), 'LCF.field? is false for an undeclared name'
check !LCF.field?(nil, :x), 'LCF.field? is false for nil, as nil.respond_to? was'
check LCF.field?(OpenStruct.new(x: 1), :x), 'LCF.field? falls back to respond_to? for a stand-in'
check !LCF.field?(OpenStruct.new(x: 1), :y), '...and says no for a name the stand-in lacks'

tree_schema = LCF::Schema::MAP_TREE
sections = LCF::Sections.new
tree_schema.each { |s| sections.add s[:name], LCF::Array1D.new('', { elements: {} }) }
check sections.field?(:initial), 'Sections#field? knows its sections'
check !sections.field?(:no_such_section), 'Sections#field? is false for an unknown section'
check !sections.respond_to?(:initial), 'Sections no longer responds to a section name'

save = LCF::SaveData.new
check save.field?(:hero), 'File#field? forwards to the root schema'
check !save.respond_to?(:hero), 'a file no longer responds to a root field name'
save[:hero] = LCF::Array1D.new('', movable)
check save[:hero].is_a?(LCF::Array1D), 'file[:name] reads a root field'
check save.delete(104).is_a?(String) && !save.key?(104), 'File#delete drops a root chunk'

# -- 2. real data: [] == the removed dotted access --------------------------------

# The removed Array1D#method_missing, `self[sym2idx[name]]`, with the
# name -> chunk id table rebuilt from the record's own schema the way the
# private #sym2idx built it (in declaration order, a repeated name's last
# declaration winning).
def legacy_index(schema)
  @legacy_index ||= {}.compare_by_identity
  @legacy_index[schema] ||= LCF.elements_of(schema).each_with_object({}) { |(id, e), h| h[e[:name]] = id }
end

def legacy_read(row, name)
  row[legacy_index(row.schema)[name]]
end

def same?(a, b)
  return a.equal?(b) if a.is_a?(LCF::Array1D) || a.is_a?(LCF::Array2D)
  return true if a.is_a?(Float) && b.is_a?(Float) && a.nan? && b.nan?
  a == b
end

$records = 0
$fields = 0

def check_record(row, path, depth = 0)
  return unless row.is_a?(LCF::Array1D) && row.schema
  $records += 1
  LCF.elements_of(row.schema).each_value do |e|
    name = e[:name]
    $fields += 1
    begin
      old = legacy_read(row, name)
    rescue StandardError => ex
      old = ex.class
    end
    begin
      now = row[name]
    rescue StandardError => ex
      now = ex.class
    end
    check same?(old, now), "#{path}[:#{name}]: [] read #{now.inspect[0, 60]}, the dotted access read #{old.inspect[0, 60]}"
    check row.field?(name), "#{path}: field?(:#{name}) is false for a declared field"
    check !row.respond_to?(name), "#{path}: still responds to :#{name}"
    next if depth >= 2
    case now
    when LCF::Array1D then check_record(now, "#{path}[:#{name}]", depth + 1)
    when LCF::Array2D then check_table(now, "#{path}[:#{name}]", 2, depth + 1)
    end
  end
end

def check_table(table, path, rows, depth = 0)
  n = 0
  table.each do |id, r|
    break if n >= rows
    n += 1
    check_record(r, "#{path}[#{id}]", depth)
  end
end

def check_game(dir)
  puts "== #{dir.sub("#{ROOT}/", '')}"
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  LCF.elements_of(db.schema).each do |id, e|
    name = e[:name]
    check same?(db[id], db[name]), "db[:#{name}] differs from db[#{id}]"
    check db.field?(name) && !db.respond_to?(name), "db: field?/respond_to? for :#{name}"
    v = db[name]
    case v
    when LCF::Array2D then check_table(v, "db[:#{name}]", 3)
    when LCF::Array1D then check_record(v, "db[:#{name}]")
    end
  end

  tree = LCF::MapTree.new(File.open(File.join(dir, 'RPG_RT.lmt'), 'rb'))
  LCF::Schema::MAP_TREE.each do |s|
    check tree.field?(s[:name]) && !tree.respond_to?(s[:name]), "tree: field?/respond_to? for :#{s[:name]}"
  end
  props = tree[:map_properties]
  first = nil
  props.each { |id, _| first ||= id }
  check first.nil? || tree[first].equal?(props[first]), 'tree[id] still indexes into the first section'
  check_table(props, 'tree[:map_properties]', 5)
  check_record(tree[:initial], 'tree[:initial]')

  Dir[File.join(dir, 'Map*.lmu')].sort.first(3).each do |f|
    unit = LCF::MapUnit.new(File.open(f, 'rb'))
    base = File.basename(f)
    LCF.elements_of(unit.schema).each do |id, e|
      check same?(unit[id], unit[e[:name]]), "#{base}[:#{e[:name]}] differs from [#{id}]"
    end
    events = unit[:events]
    check_table(events, "#{base}[:events]", 3) if events
  end
end

def discover(root)
  nep = Dir[File.join(root, 'Nepheshel206beta', '*', 'RPG_RT.ldb')].map { |f| File.dirname(f) }
  nep.sort
end

games = ARGV.dup
games = discover(File.join(ROOT, 'data')) if games.empty?
if games.empty?
  puts 'no data/Nepheshel206beta test bed (scripts/download-nepheshel.bash): real-data part skipped'
else
  games.each { |g| check_game(g) }
  puts "compared #{$fields} field reads over #{$records} real records"
end

if $failures.zero?
  puts "lcf bracket access check: #{$checks} checks passed"
else
  warn "lcf bracket access check: #{$failures} of #{$checks} checks FAILED"
end
exit($failures.zero? ? 0 : 1)
