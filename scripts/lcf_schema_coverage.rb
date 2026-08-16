#!/usr/bin/env ruby
# encoding: UTF-8
#
# LCF schema coverage: load every real test-bed RPG_RT.ldb / .lmt / Map*.lmu and
# report any chunk id the parser stores but the schema does not name. A named
# schema entry is what makes a chunk accessible to game code and what the
# test-bed walker validates; an undeclared chunk is preserved as raw bytes but is
# invisible to the runtime. This is the measuring stick for the "Support all data
# schema of LCF" TODO -- run it after editing mruby-lcf/mrblib/schema.rb to make
# sure no real-game chunk is left unnamed.
#
# Usage: ruby scripts/lcf_schema_coverage.rb [GAME_DIR ...]
# With no arguments it scans ./data for directories that contain an RPG_RT.ldb.
# Exits non-zero if any undeclared chunk is found.

require 'stringio'
require 'set'

module LCF
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
  end
  module_function :cp932_to_utf8

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')

def present_ids(obj)
  root = obj.respond_to?(:instance_variable_get) ? obj.instance_variable_get(:@root) : obj
  root = obj if root.nil?
  if root.is_a?(LCF::Sections)
    return root.instance_variable_get(:@list).flat_map { |s| present_ids(s) }.to_set
  end
  d = root.instance_variable_get(:@data) rescue nil
  d ? d.each_with_index.filter_map { |v, i| i if v }.to_set : Set.new
end

def declared_ids(schema)
  if schema.is_a?(Array)
    schema.flat_map { |s| declared_ids(s) }.to_set
  elsif schema && schema[:elements]
    schema[:elements].keys.to_set
  else
    Set.new
  end
end

$gaps = Hash.new { |h, k| h[k] = Set.new }

# Recursively compare present vs declared chunk ids at every Array1D/Array2D
# level and record undeclared ids with a path.
def scan(obj, schema, path)
  return unless schema
  if schema.is_a?(Array)
    list = obj.respond_to?(:instance_variable_get) ? obj.instance_variable_get(:@root) : obj
    list = list.instance_variable_get(:@list) if list.is_a?(LCF::Sections)
    list.each_with_index { |entry, i| scan(entry, schema[i], "#{path}/#{i}") }
    return
  end
  return if schema[:type] == :Tree
  return unless schema[:elements]
  # An Array2D is a table of records: its "present" ids are table entry keys, not
  # chunk ids, so do not compare them -- descend into each record instead.
  if schema[:type] == :Array2D
    begin
      obj.each { |_id, entry| scan(entry, schema[:elements], "#{path}[]") }
    rescue
    end
    return
  end
  # Array1D node: its indices are chunk ids -- compare against declared fields.
  present = present_ids(obj)
  declared = declared_ids(schema)
  (present - declared).sort.each { |id| $gaps[path] << id }
  schema[:elements].each do |idx, e|
    next unless e[:type] == :Array1D || e[:type] == :Array2D
    begin
      v = obj[idx]
    rescue
      next
    end
    next unless v
    if e[:type] == :Array2D
      v.each { |_id, entry| scan(entry, e[:elements], "#{path}.#{e[:name]}[]") }
    else
      scan(v, e, "#{path}.#{e[:name]}")
    end
  end
end

def schema_for(base)
  case base
  when 'RPG_RT.ldb' then LCF::Schema::DATABASE
  when 'RPG_RT.lmt' then LCF::Schema::MAP_TREE
  else LCF::Schema::MAP_UNIT
  end
end

def klass_for(base)
  case base
  when 'RPG_RT.ldb' then LCF::Database
  when 'RPG_RT.lmt' then LCF::MapTree
  else LCF::MapUnit
  end
end

games = ARGV.dup
games = Dir.glob(File.join(File.expand_path('../data', __dir__), '**', 'RPG_RT.ldb')) if games.empty?
games += Dir.glob(File.join(File.expand_path('../data', __dir__), '**', 'RPG_RT.lmt'))
games += Dir.glob(File.join(File.expand_path('../data', __dir__), '**', 'Map*.lmu'))

errors = 0
games.sort.uniq.each do |f|
  base = File.basename(f)
  begin
    obj = klass_for(base).new(File.open(f, 'rb'))
    scan(obj, schema_for(base), base)
  rescue => ex
    warn "ERROR #{f}: #{ex.class}: #{ex.message}"
    errors += 1
  end
end

if $gaps.empty?
  puts 'OK: every chunk in the test-bed data is named by the LCF schema'
else
  $gaps.sort.each do |path, ids|
    puts "#{path}: UNDECLARED #{ids.sort.inspect}"
  end
  errors += 1
end
exit(errors.zero? ? 0 : 1)
