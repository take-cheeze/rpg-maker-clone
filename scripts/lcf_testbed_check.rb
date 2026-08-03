#!/usr/bin/env ruby
# encoding: UTF-8
#
# Smoke-test the LCF loaders against real RPG Maker 2000 test-bed projects.
#
# The parser (mruby-lcf/mrblib/{lcf,schema}.rb) is written in the mruby/CRuby
# common subset, so this harness loads those exact sources under CRuby and runs
# them over a downloaded game's RPG_RT.ldb / RPG_RT.lmt / Map*.lmu. The unit
# tests in mruby-lcf/test exercise the schema against synthetic blobs; this
# exercises it against genuine editor output, which is where format surprises
# (unexpected chunk types, move-route encodings, ...) actually show up.
#
# The only native dependency of the parser is LCF.cp932_to_utf8 (uni-algo in the
# real build); here it is provided by Ruby's Windows-31J transcoder. Only
# structural, encoding-independent invariants are asserted, so the shim never
# affects the result.
#
# Usage:
#   ruby scripts/lcf_testbed_check.rb [GAME_DIR ...]
# With no arguments it scans ./data for directories that contain an RPG_RT.ldb.
# Exits non-zero if any file fails to parse or an invariant is violated.

require 'stringio'

module LCF
  # uni-algo stand-in: transcode Shift_JIS (Windows-31J) to UTF-8, degrading
  # unmappable bytes rather than aborting, mirroring the native decoder.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "�")
  end
  module_function :cp932_to_utf8

  # Referenced by a lazy default in the actor schema; RPG2000 caps at 50.
  def self.max_level; MODE == 2003 ? 99 : 50; end
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')

class Checker
  def initialize
    @errors = 0
    @maps = 0
    @events = 0
    @move_commands = 0
  end

  attr_reader :errors

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  # Recursively read every declared field of an Array1D so any chunk whose bytes
  # do not match its schema type raises here instead of at game runtime.
  def walk(row, schema, path)
    return unless schema && schema[:elements]
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
      when :move_commands
        v&.each do |mc|
          @move_commands += 1
          unless (0..41).cover?(mc.command_id)
            fail "#{path}.#{e[:name]}: move command id out of range: #{mc.command_id}"
          end
        end
      end
    end
  end

  # Report the editor edition (RPG2000 vs RPG2003) the database was authored in,
  # and for a 2003 project prove the 2003-only structures actually decode: the
  # Classes (職業) section must be readable and every actor's class_id must name a
  # real class (or 0 for none). RPG2000 databases must not carry that section.
  def check_maker(db)
    maker = db.maker
    puts "  maker: RPG Maker #{maker}"
    if db.rpg2003?
      classes = db.job
      fail 'ldb: 2003 database has no Classes section' unless classes
      ids = {}
      classes&.each { |id, _c| ids[id] = true }
      db.player&.each do |aid, actor|
        cid = actor.class_id.to_i
        next if cid.zero?
        fail "ldb.player[#{aid}].class_id #{cid} has no matching class" unless ids[cid]
      end
      puts "  classes: #{ids.size}"
    elsif db.job
      fail 'ldb: RPG2000 database unexpectedly carries a Classes section (chunk 30)'
    end
  end

  def check_game(dir)
    puts "== #{dir} =="

    db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
    walk(db, LCF::Schema::DATABASE, 'ldb')
    check_maker(db)

    lmt = LCF::MapTree.new(File.open(File.join(dir, 'RPG_RT.lmt'), 'rb'))
    fail 'map tree has no start map' if lmt.initial.initial_map_id.to_i <= 0
    lmt.map_properties.each { |id, m| walk(m, LCF::Schema::MAP_TREE[0], "lmt[#{id}]") }

    Dir[File.join(dir, 'Map*.lmu')].sort.each do |f|
      base = File.basename(f)
      lmu = LCF::MapUnit.new(File.open(f, 'rb'))
      walk(lmu, LCF::Schema::MAP_UNIT, base)
      w = lmu.width.to_i
      h = lmu.height.to_i
      fail "#{base}: non-positive dimensions #{w}x#{h}" if w <= 0 || h <= 0
      lower = lmu.lower_layer
      upper = lmu.upper_layer
      fail "#{base}: lower layer #{lower.size} != #{w}x#{h}" if lower && lower.size != w * h
      fail "#{base}: upper layer #{upper.size} != #{w}x#{h}" if upper && upper.size != w * h
      lmu.events.each { |_id, _ev| @events += 1 }
      @maps += 1
    end
  rescue => ex
    fail "#{dir}: #{ex.class}: #{ex.message}"
  end

  def report
    puts "checked #{@maps} maps, #{@events} events, #{@move_commands} move commands"
    if @errors.zero?
      puts 'OK: all test-bed data parsed cleanly'
    else
      warn "#{@errors} error(s)"
    end
  end
end

def discover_games(root)
  return [] unless Dir.exist?(root)
  Dir.glob(File.join(root, '**', 'RPG_RT.ldb')).map { |f| File.dirname(f) }.sort.uniq
end

games = ARGV.dup
games = discover_games(File.expand_path('../data', __dir__)) if games.empty?

if games.empty?
  warn 'no test-bed game found (pass a GAME_DIR or run scripts/download-*.bash first)'
  exit 0
end

checker = Checker.new
games.each { |g| checker.check_game(g) }
checker.report
exit(checker.errors.zero? ? 0 : 1)
