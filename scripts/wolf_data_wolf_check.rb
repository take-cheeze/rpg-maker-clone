#!/usr/bin/env ruby
# encoding: UTF-8
#
# Cross-validates Wolf::DataWolf (the Data.wolf packed-release reader,
# mruby-wolf/mrblib/data_wolf.rb) against a real project instead of only
# synthetic fixtures: packs the whole Data/ tree of a real, loose-tree WOLF
# RPG Editor project (scripts/download-wolfrpg-sample.bash's own sample game,
# by default) into a fresh Data.wolf with Wolf::DataWolf.pack, points a
# second Wolf::Project at that packed copy, and asserts every field
# scripts/wolf_testbed_check.rb's own Checker checks -- game title, map tree,
# tilesets, all three databases, common events, and every map's own layers
# and events -- comes back byte-for-byte identical between the loose project
# and the packed one.
#
# This is deliberately a *round-trip* check (this reader's own .pack builds
# the fixture, this reader's own reading unpacks it) -- see data_wolf.rb's
# own file header for why that alone does not prove format compatibility
# with a real DxLib-built Data.wolf the way scripts/wolf_testbed_check.rb's
# genuine editor output does for the loose-tree side. What it does prove: the
# packed-vs-loose backing-store seam in Wolf::Project#read is wired correctly,
# and the reader/writer agree on every byte of a real project's data -- 660
# files, nested directories, a project several times the size any hand-built
# unit-test fixture would use.
#
# Usage:
#   ruby scripts/wolf_data_wolf_check.rb [PROJECT_DIR]
# With no argument it uses data/wolfrpg-sample-3.724/WOLF_RPG_Editor3, the
# default download-wolfrpg-sample.bash target. Exits non-zero on any mismatch.

require 'stringio'
require 'fileutils'
require 'tmpdir'

module LCF
  def self.cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
end

module Wolf
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
load File.join(mrblib, 'wolf_crypt_pro.rb')
load File.join(mrblib, 'data_wolf.rb')
load File.join(mrblib, 'data.rb')

loose_dir = ARGV[0] || File.expand_path('../data/wolfrpg-sample-3.724/WOLF_RPG_Editor3', __dir__)
unless Wolf::Project.project?(loose_dir)
  puts "No loose WOLF RPG Editor project at #{loose_dir}; nothing to check."
  exit 0
end

# Every file under Data/, archive-relative ('/' separators, no "Data/" prefix
# -- see data_wolf.rb's own file header on why the archive root is Data/'s
# own contents, not a wrapper folder).
data_root = File.join(loose_dir, 'Data')
files = []
Dir.glob(File.join(data_root, '**', '*')).sort.each do |path|
  next unless File.file?(path)
  rel = path[(data_root.bytesize + 1)..-1].tr('\\', '/')
  files << [rel, File.binread(path)]
end
puts "Packing #{files.size} files (#{files.sum { |_, b| b.bytesize }} bytes) from #{data_root}"

archive = Wolf::DataWolf.pack(files)
puts "Data.wolf: #{archive.bytesize} bytes"

Dir.mktmpdir('wolf-data-wolf-check') do |packed_dir|
  File.binwrite(File.join(packed_dir, 'Data.wolf'), archive)
  raise 'Wolf::Project.project? did not recognize the packed copy' unless Wolf::Project.project?(packed_dir)

  loose = Wolf::Project.new(loose_dir)
  packed = Wolf::Project.new(packed_dir)

  errors = 0
  check = lambda do |label, a, b|
    if a != b
      errors += 1
      warn "  MISMATCH #{label}: loose=#{a.inspect} packed=#{b.inspect}"
    end
  end

  check.call('game.title', loose.game.title, packed.game.title)
  check.call('game.tile_size', loose.game.tile_size, packed.game.tile_size)
  check.call('map_tree.map_ids', loose.map_tree.map_ids, packed.map_tree.map_ids)
  check.call('tilesets.size', loose.tilesets.size, packed.tilesets.size)
  loose.databases.each do |key, db|
    check.call("databases[#{key}].types.size", db.types.size, packed.databases[key].types.size)
  end
  check.call('common_events.size', loose.common_events.size, packed.common_events.size)

  maps = 0
  loose.map_tree.map_ids.each do |id|
    file = loose.map_file(id)
    next unless file
    lm = loose.map(id)
    pm = packed.map(id)
    maps += 1
    check.call("map #{id} (#{file}) width", lm.width, pm.width)
    check.call("map #{id} (#{file}) height", lm.height, pm.height)
    check.call("map #{id} (#{file}) layers", lm.layers, pm.layers)
    check.call("map #{id} (#{file}) events.size", lm.events.size, pm.events.size)
    lm.events.zip(pm.events).each do |le, pe|
      check.call("map #{id} event #{le.id} pages.size", le.pages.size, pe.pages.size)
    end
  end
  puts "Compared #{maps} maps."

  if errors > 0
    warn "#{errors} mismatch(es) between the loose project and its packed round-trip"
    exit 1
  end
  puts 'Wolf::DataWolf packed round-trip matches the loose project exactly.'
end
