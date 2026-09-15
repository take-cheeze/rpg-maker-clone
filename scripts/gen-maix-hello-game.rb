#!/usr/bin/env ruby
# encoding: UTF-8
#
# Author the minimal synthetic RPG Maker 2000 game in data/maix-hello/ that
# the Maix Amigo port boots to its title screen (see app/maix/README.md).
# Nothing here is vendored from any real game: the database carries only a
# System section (title graphic name, everything else default) and a Terms
# section (three English menu labels -- ASCII, so the embedded shinonome
# font covers every glyph), the map tree is an empty property table plus
# start position, and the title picture is generated below. The title scene
# degrades gracefully without the rest (nil picture/skin/music/se all have
# blank fallbacks), so this is everything it reads.
#
# Built with the project's own LCF reader/writer sources (loaded the same
# way scripts/lcf_testbed_check.rb loads them), so whatever this writes is
# by construction parseable by the firmware's identical reader.
#
# Usage:
#   ruby scripts/gen-maix-hello-game.rb [OUT_DIR, default data/maix-hello]

require 'stringio'
require 'zlib'
require 'fileutils'

module LCF
  # Same uni-algo stand-ins scripts/lcf_testbed_check.rb uses (ASCII-only
  # content here, so the transcoder choice is unobservable).
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
  end
  def utf8_to_cp932(s)
    s.encode('Windows-31J', invalid: :replace, undef: :replace, replace: '?').b
  end
  module_function :cp932_to_utf8, :utf8_to_cp932
  def self.max_level; 50; end
  MODE = 2000
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')
load File.join(mrblib, 'lcf_file.rb')

OUT = ARGV[0] || File.expand_path('../data/maix-hello', __dir__)
FileUtils.mkdir_p(File.join(OUT, 'Title'))

# RPG_RT.ldb: System (22) + Terms (21) sections only. The party field stays
# empty (no actors ship): rpg2k_testbed_logic_check.rb scans every game dir
# including this one, and an absent party must read back as [] (not nil),
# or Game::Party falls back to `db.system`, which only resolves under mruby
# (under CRuby it hits Kernel#system -- see AGENTS.md).
db = LCF::Database.new
sys_schema = LCF::Schema::DATABASE[:elements][22]
sys = LCF::Array1D.new('', sys_schema)
sys[:title] = 'maix'
sys[:system_graphic] = ''
sys[:party] = []
db[22] = sys
terms = LCF::Array1D.new('', LCF::Schema::DATABASE[:elements][21])
terms[:new_game] = 'New Game'
terms[:continue] = 'Continue'
terms[:shutdown] = 'Shutdown'
db[21] = terms
File.binwrite(File.join(OUT, 'RPG_RT.ldb'), db.to_lcf)

# RPG_RT.lmt: empty property table, empty tree, start position only. The
# Array-schema sections are not writable through the API, so the framing
# bytes are assembled by hand from LCF.write_ber (header + zero-row
# properties + zero-map tree); the start-position table goes through a
# throwaway Array1D since it is an ordinary chunk list. The layout is what
# scripts/lcf_testbed_check.rb parses out of every genuine .lmt.
lmt = LCF.write_ber(10) + 'LcfMapTree'
lmt += LCF.write_ber(0)
lmt += LCF.write_ber(0) + LCF.write_ber(0)
start_schema = { elements: {
  1 => { name: :initial_map_id, type: :int },
  2 => { name: :initial_x, type: :int },
  3 => { name: :initial_y, type: :int },
} }
start = LCF::Array1D.new('', start_schema)
start[1] = 1
start[2] = 8
start[3] = 10
lmt += start.to_lcf(false)
File.binwrite(File.join(OUT, 'RPG_RT.lmt'), lmt)

# Title/maix.png: 320x240 solid teal with a white border (orientation proof
# on a panel whose rotation is still an open question -- see app/maix).
# Minimal stdlib PNG writer: signature + IHDR + IDAT(zlib, filter 0) + IEND.
def png_chunk(type, data)
  [data.bytesize, type, data, Zlib.crc32(type + data)].pack('NA4A*N')
end
w, h = 320, 240
raw = String.new(capacity: h * (1 + w * 3))
h.times do |y|
  raw << 0.chr
  w.times do |x|
    edge = x < 2 || y < 2 || x >= w - 2 || y >= h - 2
    raw << (edge ? "\xFF\xFF\xFF" : "\x00\x80\x80")
  end
end
png = "\x89PNG\r\n\x1A\n".b
png += png_chunk('IHDR', [w, h, 8, 2, 0, 0, 0].pack('NNCCCCC'))
png += png_chunk('IDAT', Zlib::Deflate.deflate(raw))
png += png_chunk('IEND', '')
File.binwrite(File.join(OUT, 'Title', 'maix.png'), png)

puts "wrote #{OUT} (ldb=#{File.size(File.join(OUT, 'RPG_RT.ldb'))} " \
     "lmt=#{File.size(File.join(OUT, 'RPG_RT.lmt'))} " \
     "png=#{File.size(File.join(OUT, 'Title', 'maix.png'))})"
