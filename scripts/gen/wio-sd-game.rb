#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the synthetic RPG Maker 2000 game CI's wio-renode job plays from a simulated microSD card: a database that
# names a title graphic and a system graphic, a map tree, and both images as 8-bit palette PNGs, so
# scripts/wio/sd_bitmaps.rb packs them for the QSPI image cache. Nothing in it comes from a real game.
#
#   ruby scripts/gen/wio-sd-game.rb OUT_DIR

require 'stringio'
require 'zlib'
require 'fileutils'

# The LCF writer is loaded as scripts/gen/maix-hello-game.rb loads it (ASCII-only strings here).
module LCF
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J').encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
  end

  def utf8_to_cp932(s)
    s.encode('Windows-31J', invalid: :replace, undef: :replace, replace: '?').b
  end
  module_function :cp932_to_utf8, :utf8_to_cp932

  def self.max_level = 50
end

mrblib = File.expand_path('../../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
require_relative '../lcf/native_stand_ins'
%w[schema lcf_file save_typed save_typed_accessors].each { |f| load File.join(mrblib, "#{f}.rb") }

out = ARGV[0] or abort 'usage: wio-sd-game.rb OUT_DIR'
FileUtils.mkdir_p([File.join(out, 'Title'), File.join(out, 'System')])

db = LCF::Database.new
sys = LCF::Array1D.new('', LCF::Schema::DATABASE[:elements][22])
sys[:title] = 'wio'
sys[:system_graphic] = 'wio'
sys[:party] = []
db[22] = sys
terms = LCF::Array1D.new('', LCF::Schema::DATABASE[:elements][21])
terms[:new_game] = 'New Game'
terms[:continue] = 'Continue'
terms[:shutdown] = 'Shutdown'
db[21] = terms
File.binwrite(File.join(out, 'RPG_RT.ldb'), db.to_lcf)

# Header, an empty property table and tree, then the start position (scripts/gen/maix-hello-game.rb builds it alike).
start = LCF::Array1D.new('', { elements: {
                             1 => { name: :initial_map_id, type: :int },
                             2 => { name: :initial_x, type: :int },
                             3 => { name: :initial_y, type: :int },
                           } })
start[1] = 1
start[2] = 8
start[3] = 10
File.binwrite(File.join(out, 'RPG_RT.lmt'),
              LCF.write_ber(10) + 'LcfMapTree' + LCF.write_ber(0) * 3 + start.to_lcf(false))

def png_chunk(type, data)
  [data.bytesize, type, data, Zlib.crc32(type + data)].pack('NA4A*N')
end

# An 8-bit palette PNG of +w+ x +h+ whose pixel (x, y) is palette index yield(x, y).
def palette_png(path, w, h, palette)
  raw = +''.b
  h.times do |y|
    raw << "\0"
    w.times { |x| raw << yield(x, y) }
  end
  File.binwrite(path, "\x89PNG\r\n\x1A\n".b + png_chunk('IHDR', [w, h, 8, 3, 0, 0, 0].pack('NNC5')) +
                      png_chunk('PLTE', palette.flatten.pack('C*')) + png_chunk('IDAT', Zlib::Deflate.deflate(raw)) +
                      png_chunk('IEND', ''))
end

colours = [[0, 0, 0], [0, 128, 128], [255, 255, 255], [32, 32, 160], [200, 160, 40]]
# Title: teal with a white border and a band.
palette_png(File.join(out, 'Title', 'wio.png'), 320, 240, colours) do |x, y|
  if x < 2 || y < 2 || x >= 318 || y >= 238 then 2
  elsif y.between?(100, 139) then 4
  else 1
  end
end
# System: the 160x80 skin; index 0 is its colour key, so the sheet's own regions use the rest.
palette_png(File.join(out, 'System', 'wio.png'), 160, 80, colours) do |x, y|
  if x < 32 && y < 32 then 3
  elsif x < 64 then ((x + y) % 8).zero? ? 2 : 0
  else (x / 16 + y / 16) % 4 + 1
  end
end

puts "wrote #{out}"
