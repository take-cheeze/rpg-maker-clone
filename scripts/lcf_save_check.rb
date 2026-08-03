#!/usr/bin/env ruby
# encoding: UTF-8
#
# Analyse and smoke-test the LCF save-data loader against a real Save<N>.lsd.
#
# The database/map schemas (ADR 0002 / 0008) are exercised against downloaded
# test-bed games by scripts/lcf_testbed_check.rb, but the save-data schema
# (ADR 0009, mruby-lcf/mrblib/schema.rb `SAVE_DATA`) was only ever run over
# synthetic blobs -- no real `.lsd` fixture was bundled. A running RPG Maker
# 2000/2003 game (or EasyRPG Player) writes a genuine Save<N>.lsd when the
# player saves; this harness loads the exact mruby/CRuby-common parser sources
# over such a file and:
#
#   * verifies the "LcfSaveData" header,
#   * lists every top-level chunk actually present, flagging which are described
#     by the schema and which are still UNDOCUMENTED (chunks 102, 109, 112, 113,
#     114, 200 in practice -- see ADR 0009),
#   * recursively reads every declared field of the documented sections so a
#     chunk whose bytes do not match its schema type raises here instead of at
#     game runtime, and
#   * prints a short human-readable summary (hero position, party, switches,
#     variables, save count, ...).
#
# The only native dependency of the parser is LCF.cp932_to_utf8 (uni-algo in the
# real build); here it is provided by Ruby's Windows-31J transcoder.
#
# Usage:
#   ruby scripts/lcf_save_check.rb [SAVE.lsd ...]
# With no arguments it scans ./data for Save*.lsd files. Exits non-zero if any
# file fails to parse or a documented invariant is violated.

require 'stringio'

module LCF
  # uni-algo stand-in: transcode Shift_JIS (Windows-31J) to UTF-8, degrading
  # unmappable bytes rather than aborting, mirroring the native decoder.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
  module_function :cp932_to_utf8

  # Referenced by a lazy default in the actor schema; RPG2000 caps at 50.
  def self.max_level; MODE == 2003 ? 99 : 50; end
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')

class SaveChecker
  attr_reader :errors

  def initialize
    @errors = 0
    @files = 0
  end

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  # Recursively read every declared field so any chunk whose bytes do not match
  # its schema type raises here instead of at game runtime.
  def walk(row, schema, path)
    return unless row && schema && schema[:elements]
    schema[:elements].each do |idx, e|
      begin
        v = row[idx]
      rescue => ex
        fail "#{path}.#{e[:name]} (chunk #{idx}, #{e[:type]}): #{ex.class}: #{ex.message}"
        next
      end
      case e[:type]
      when :Array2D
        v&.each { |id, r| walk(r, e, "#{path}.#{e[:name]}[#{id}]") }
      when :Array1D
        walk(v, e, "#{path}.#{e[:name]}") if v
      end
    end
  end

  def check_save(path)
    puts "== #{path} =="
    save = LCF::SaveData.new(File.open(path, 'rb'))
    root = save.instance_variable_get(:@root)     # top-level Array1D
    raw  = root.instance_variable_get(:@data)     # raw chunk bytes by index
    schema = LCF::Schema::SAVE_DATA[:elements]

    present = []
    raw.each_with_index { |v, i| present << i unless v.nil? }

    known = present.select { |i| schema.key?(i) }
    undoc = present - known

    puts "  chunks present: #{present.join(', ')}"
    known.each do |idx|
      e = schema[idx]
      printf("    chunk %-4d %-8d %s (%s)\n", idx, raw[idx].bytesize, e[:name], e[:type])
    end
    # Read every declared field of every documented section so a mistyped chunk
    # raises here rather than at game runtime.
    walk(save, LCF::Schema::SAVE_DATA, 'save')
    unless undoc.empty?
      puts "  undocumented chunks (not in schema.rb SAVE_DATA):"
      undoc.each { |idx| printf("    chunk %-4d %-8d (undocumented)\n", idx, raw[idx].bytesize) }
    end

    missing = schema.keys.sort - present
    puts "  schema chunks absent from this save: #{missing.join(', ')}" unless missing.empty?

    summarise(save, raw, schema)
    @files += 1
  rescue => ex
    fail "#{path}: #{ex.class}: #{ex.message}"
  end

  # Cross-check the decoded values a save always carries -- these confirm the
  # documented sections read as the right types rather than merely not raising.
  def summarise(save, raw, schema)
    t = save.title
    puts "  title:   hero=#{t.hero_name.inspect} lv=#{t.hero_level} hp=#{t.hero_hp} " \
         "timestamp=#{t.timestamp.inspect}"
    sys = save[101] # avoid Kernel#system when reached by name under CRuby
    if sys
      sw = sys.switches
      va = sys.variables
      puts "  system:  scene=#{sys.scene} frame=#{sys.frame_count} " \
           "save_count=#{sys.save_count} save_slot=#{sys.save_slot}"
      puts "  switches: #{sw ? "#{sw.count(true)} on / #{sw.size}" : 'nil'}   " \
           "variables: #{va ? "#{va.count { |x| x != 0 }} nonzero / #{va.size}" : 'nil'}"
      fail 'switches decoded to a non-boolean array' if sw && !sw.all? { |x| x == true || x == false }
    end
    h = save.hero
    if h
      puts "  hero:    map=#{h.map_id} pos=(#{h.x},#{h.y}) dir=#{h.direction} " \
           "charset=#{h.charset_name.inspect}"
      fail 'hero has non-positive map id' if h.map_id.to_i <= 0
    end
    actors = 0
    (save.actors.each { |_id, _a| actors += 1 } rescue nil)
    puts "  party:   #{actors} saved actor entrie(s)"
  end

  def report
    puts "checked #{@files} save file(s)"
    if @errors.zero?
      puts 'OK: all save data parsed cleanly'
    else
      warn "#{@errors} error(s)"
    end
  end
end

def discover_saves(root)
  return [] unless Dir.exist?(root)
  Dir.glob(File.join(root, '**', 'Save*.lsd')).sort.uniq
end

saves = ARGV.dup
saves = discover_saves(File.expand_path('../data', __dir__)) if saves.empty?

if saves.empty?
  warn 'no Save*.lsd found (pass a path, or generate one -- see ' \
       'scripts/run-nepheshel-easyrpg-wine.bash)'
  exit 0
end

checker = SaveChecker.new
saves.each { |s| checker.check_save(s) }
checker.report
exit(checker.errors.zero? ? 0 : 1)
