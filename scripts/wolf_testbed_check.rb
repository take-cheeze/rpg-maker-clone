#!/usr/bin/env ruby
# encoding: UTF-8
#
# Smoke-test the WOLF RPG Editor (ウディタ) data loaders against a real project.
#
# The parser (mruby-wolf/mrblib/{wolf,data}.rb) is written in the mruby/CRuby
# common subset, so this harness loads those exact sources under CRuby and
# parses a downloaded project's Game.dat, MapTree.dat, TileSetData.dat, all
# three databases, CommonEvent.dat and every map under Data/MapData. The unit
# tests in mruby-wolf/test exercise the format against small synthetic blobs;
# this exercises it against genuine editor output, the way
# scripts/lcf_testbed_check.rb does for RPG Maker 2000/2003.
#
# Usage:
#   ruby scripts/wolf_testbed_check.rb [PROJECT_DIR ...]
# With no arguments it scans ./data for directories that contain
# Data/BasicData/Game.dat. Exits non-zero if any file fails to parse or an
# invariant is violated.

require 'stringio'

module LCF
  # uni-algo stand-in used by mruby-wolf's Wolf.sjis_to_utf8 (only reached for
  # a v2.x, Shift_JIS project -- the current sample game is v3.5+/UTF-8, but
  # the fallback path is exercised by mruby-wolf/test's own unit tests).
  def self.cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
end

module Wolf
  # Native (mruby-wolf/src/lz4.cxx) in the real build; this is CRuby's stand-in
  # for the host check, ported from that C++ implementation rather than kept
  # as a second hand-maintained decoder. See docs/adr/0064's note on why the
  # naive interpreted version (many small String allocations per token) is
  # gone from mrblib entirely.
  module LZ4
    def self.decompress(src, dst_size)
      out = +''
      n = src.bytesize
      i = 0
      while i < n
        token = src.getbyte(i)
        i += 1
        lit = token >> 4
        if lit == 15
          loop do
            raise Wolf::Error, 'LZ4: truncated literal length' if i >= n
            b = src.getbyte(i)
            i += 1
            lit += b
            break if b != 255
          end
        end
        if lit > 0
          raise Wolf::Error, 'LZ4: truncated literals' if i + lit > n
          out << src.byteslice(i, lit)
          i += lit
        end
        break if i >= n
        raise Wolf::Error, 'LZ4: truncated match offset' if i + 2 > n
        offset = src.getbyte(i) | (src.getbyte(i + 1) << 8)
        i += 2
        raise Wolf::Error, 'LZ4: zero match offset' if offset == 0
        raise Wolf::Error, 'LZ4: match offset before start of output' if offset > out.bytesize
        mlen = token & 0xf
        if mlen == 15
          loop do
            raise Wolf::Error, 'LZ4: truncated match length' if i >= n
            b = src.getbyte(i)
            i += 1
            mlen += b
            break if b != 255
          end
        end
        mlen += Wolf::LZ4::MIN_MATCH
        start = out.bytesize - offset
        if offset >= mlen
          out << out.byteslice(start, mlen)
        else
          old_size = out.bytesize
          out << ("\0" * mlen)
          mlen.times { |k| out.setbyte(old_size + k, out.getbyte(start + k)) }
        end
      end
      if out.bytesize != dst_size
        raise Wolf::Error, "LZ4: decoded #{out.bytesize} bytes, expected #{dst_size}"
      end
      out
    end
  end
end

mrblib = File.expand_path('../mruby-wolf/mrblib', __dir__)
load File.join(mrblib, 'wolf.rb')
load File.join(mrblib, 'data.rb')

class Checker
  def initialize
    @errors = 0
    @maps = 0
    @events = 0
    @commands = 0
  end

  attr_reader :errors

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  def check_project(dir)
    puts "== #{dir}"
    project = Wolf::Project.new(dir)

    check_game_dat(project.game)
    check_map_tree(project.map_tree)
    check_tilesets(project.tilesets)
    project.databases.each { |key, db| check_database(key, db) }
    check_common_events(project.common_events)
    check_maps(project)

    puts "  ok: #{@maps} maps, #{@events} events, #{@commands} commands"
  rescue Wolf::Error => e
    fail "#{dir}: #{e.class}: #{e.message}"
  end

  def check_game_dat(g)
    fail "Game.dat: empty title" if g.title.strip.empty?
    fail "Game.dat: tile size #{g.tile_size}" unless [16, 32, 40, 48].include?(g.tile_size)
    fail "Game.dat: screen #{g.screen_width}x#{g.screen_height}" unless g.screen_width > 0 && g.screen_height > 0
    fail "Game.dat: fps #{g.fps}" unless [30, 60].include?(g.fps)
    fail "Game.dat: character directions #{g.character_directions}" unless [4, 8].include?(g.character_directions)
  end

  def check_map_tree(t)
    fail "MapTree.dat: no entries" if t.entries.empty?
    ids = t.map_ids
    fail "MapTree.dat: duplicate map ids" if ids.uniq.size != ids.size
  end

  def check_tilesets(ts)
    fail "TileSetData.dat: no tilesets" if ts.size == 0
    ts.tilesets.each do |tileset|
      tileset.flags.each do |f|
        fail "tileset #{tileset.index}: tag #{f.tag} out of range" unless (0..99).cover?(f.tag)
      end
    end
  end

  def check_database(key, db)
    db.types.each do |t|
      fail "#{key} db type #{t.index} (#{t.name.inspect}): field/data mismatch" if t.fields.nil? || t.data.nil?
      t.data.each do |d|
        t.fields.each do |f|
          v = d[f]
          if f.string?
            fail "#{key}.#{t.name}.#{d.name}.#{f.name}: string value is #{v.class}" unless v.is_a?(String) || v.nil?
          else
            fail "#{key}.#{t.name}.#{d.name}.#{f.name}: number value is #{v.class}" unless v.is_a?(Integer) || v.nil?
          end
        end
      end
    end
  end

  def check_common_events(ce)
    fail "CommonEvent.dat: no events" if ce.size == 0
    ce.events.each do |e|
      walk_commands(e.commands, "common event #{e.id} (#{e.name})")
    end
  end

  def check_maps(project)
    project.map_tree.map_ids.each do |id|
      file = project.map_file(id)
      next unless file
      map = project.map(id)
      @maps += 1
      fail "#{file}: bad size #{map.width}x#{map.height}" if map.width <= 0 || map.height <= 0
      fail "#{file}: #{map.layers.size} layers, declared #{map.layer_count}" unless map.layers.empty? || map.layers.size == map.layer_count
      map.layers.each_with_index do |layer, li|
        fail "#{file}: layer #{li} has #{layer.size} cells, expected #{map.width * map.height}" unless layer.size == map.width * map.height
      end
      map.events.each do |ev|
        @events += 1
        ev.pages.each do |page|
          walk_commands(page.commands, "#{file} event #{ev.id} page #{page.index}")
        end
      end
    end
  end

  def walk_commands(cmds, path)
    cmds.each do |c|
      @commands += 1
      next unless c.respond_to?(:route?) && c.route?
      walk_commands(c.route, "#{path} move route")
    end
  end
end

dirs = ARGV.dup
if dirs.empty?
  data_dir = File.expand_path('../data', __dir__)
  if Dir.exist?(data_dir)
    Dir.children(data_dir).sort.each do |name|
      d = File.join(data_dir, name)
      dirs << d if Wolf::Project.project?(File.join(d, 'WOLF_RPG_Editor3'))
      dirs << d if Wolf::Project.project?(d)
    end
  end
end

if dirs.empty?
  puts 'No WOLF RPG Editor project found under ./data; nothing to check.'
  exit 0
end

checker = Checker.new
dirs.uniq.each do |d|
  root = Wolf::Project.project?(d) ? d : File.join(d, 'WOLF_RPG_Editor3')
  checker.check_project(root)
end

if checker.errors > 0
  warn "#{checker.errors} check(s) failed"
  exit 1
end
puts 'All WOLF RPG Editor test-bed checks passed.'
