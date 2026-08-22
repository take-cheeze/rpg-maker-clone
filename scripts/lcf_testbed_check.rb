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

  # The RPG2003 database-wide Battle Commands list (chunk 29): present in a 2003
  # database with a non-empty `commands` table (field 10), and every actor's /
  # class's own `battle_commands` (field 80) positive reference actually naming
  # one of those commands. 0 (Row) and -1 (empty slot) name no entry -- they are
  # caller-handled sentinels (per the chunk-29 schema) -- and are skipped here,
  # the way #check_maker skips a zero class_id. A 2000 database must never carry
  # the list at all (its editor has no such tab), mirroring the Classes-section
  # (chunk 30) assertion above. This is the cross-reference, plus the 2000
  # negative, that the structural pass in #walk and rpg2k3_battle_command_check
  # .rb's top-level decode do not assert -- the "second form of evidence" ADR
  # 0048 deferred, closing the gap the way every other 2003-specific table here
  # is closed.
  def check_battlecommands(db)
    if db.rpg2003?
      bc = db.battlecommands
      fail 'ldb: 2003 database has no Battle Commands list (chunk 29)' unless bc
      cmds = bc && bc.commands
      fail 'ldb: 2003 Battle Commands list has no commands (field 10)' unless cmds
      ids = {}
      cmds&.each { |id, _c| ids[id] = true }
      %w[player job].each do |table|
        db.send(table)&.each do |id, row|
          row.battle_commands&.each do |rid|
            next unless rid.is_a?(Integer) && rid.positive?
            fail "ldb.#{table}[#{id}].battle_commands reference #{rid} has no matching command" unless ids[rid]
          end
        end
      end
      puts "  battlecommands: #{ids.size} commands"
    elsif db.battlecommands
      fail 'ldb: RPG2000 database unexpectedly carries a Battle Commands list (chunk 29)'
    end
  end

  def check_game(dir)
    puts "== #{dir} =="

    db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
    walk(db, LCF::Schema::DATABASE, 'ldb')
    check_maker(db)
    check_battlecommands(db)

    lmt = LCF::MapTree.new(File.open(File.join(dir, 'RPG_RT.lmt'), 'rb'))
    fail 'map tree has no start map' if lmt.initial.initial_map_id.to_i <= 0
    lmt.map_properties.each { |id, m| walk(m, LCF::Schema::MAP_TREE[0], "lmt[#{id}]") }

    Dir[File.join(dir, 'Map*.lmu')].sort.each do |f|
      base = File.basename(f)
      original = File.binread(f)
      lmu = LCF::MapUnit.new(StringIO.new(original.dup))
      walk(lmu, LCF::Schema::MAP_UNIT, base)
      # A genuine .lmu carries a trailing 0x00 root terminator that .lsd/.ldb
      # do not -- #to_lcf used to drop it for every file type, so a
      # from-scratch or round-tripped map file came out one byte short and a
      # genuine RPG_RT.exe hung on a black screen trying to load one.
      rebuilt = lmu.to_lcf
      fail "#{base}: round-trip not byte-exact (#{rebuilt.bytesize} vs #{original.bytesize} bytes)" if rebuilt != original
      w = lmu.width.to_i
      h = lmu.height.to_i
      fail "#{base}: non-positive dimensions #{w}x#{h}" if w <= 0 || h <= 0
      lower = lmu.lower_layer
      upper = lmu.upper_layer
      fail "#{base}: lower layer #{lower.size} != #{w}x#{h}" if lower && lower.size != w * h
      fail "#{base}: upper layer #{upper.size} != #{w}x#{h}" if upper && upper.size != w * h
      check_generator(base, lmu)
      lmu.events.each { |_id, _ev| @events += 1 }
      @maps += 1
    end
  rescue => ex
    fail "#{dir}: #{ex.class}: #{ex.message}"
  end

  # The RPG2003 dungeon-generator block (chunks 40-62) and the 2k3e save counter
  # (90). These are not documented on the 200X wiki's マップ page, so their ids,
  # types and defaults come from liblcf — which means they are worth asserting
  # against real bytes rather than trusting.
  #
  # Two things could silently go wrong: an id could be attached to the wrong
  # field (the values would still parse, just as the wrong thing), and a width
  # could be misread (chunk 62 is shorts, and reading it as int32 yields
  # plausible-looking large numbers rather than an error). Both are caught by
  # checking that what comes out is the shape the format promises.
  def check_generator(base, lmu)
    # Every declared field must materialise, from the file or from its default,
    # so a map that omits the whole block still answers.
    fail "#{base}: generator_width did not default" if lmu.generator_width.nil?
    fail "#{base}: generator_surround did not default" if lmu.generator_surround.nil?
    h = lmu.generator_height
    fail "#{base}: generator_height #{h.inspect} not a positive int" if h.nil? || h < 1

    # The room slots are parallel arrays: nine x/y coordinates and their tile
    # ids. A wrong element width would change these counts.
    gx = lmu.generator_x
    gy = lmu.generator_y
    fail "#{base}: generator_x is #{gx.size} values, expected 9" if gx && gx.size != 9
    fail "#{base}: generator_y is #{gy.size} values, expected 9" if gy && gy.size != 9

    ids = lmu.generator_tile_ids
    return unless ids
    fail "#{base}: generator_tile_ids is #{ids.size} values, expected 18" if ids.size != 18
    # Read as shorts these are ordinary RPG2000 tile ids; read as int32 they run
    # into the millions. Bound them by the same range the map layers use.
    bad = ids.reject { |t| t >= 0 && t <= 20_000 }
    fail "#{base}: generator_tile_ids out of tile range: #{bad.first(4).inspect}" unless bad.empty?
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
