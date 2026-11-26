#!/usr/bin/env ruby
# frozen_string_literal: true

# Packs a game directory into the image the wio_renode_game firmware reads
# (layout: app/wio/src/wio_game_rom.h). Files land under /rom/ (GAME_DIR);
# --add puts one more file at an absolute path (the font, /gothic.bin).
#
#   scripts/wio/game_rom.rb OUT GAME_DIR [--config 'k=v;k=v'] [--add LOCAL:PATH]...
#                           [--exclude DIR,DIR] [--max-file BYTES]
#                           [--bitmaps DIR,DIR | --no-bitmaps] [--bitmaps-out FILE]
#                           [--limit BYTES]
#
# Audio, Movie and the Windows binaries are left out by default: the Wio
# build plays no sound and the 16 MB window has to hold the rest.
#
# Palette images under the --bitmaps folders (or files, game-relative) go in
# already decoded, at /rgss/bitmaps (the section ROM_BITMAP in
# mruby-rgss/src/lib.cxx reads in place), in place of their files: in the
# order given, for as long as the window has room. scripts/wio/rom_bitmaps.cxx decodes them with
# the runtime's own decoders. --bitmaps-out also writes that section alone,
# for a host run (RGSS_ROM_BITMAPS_IMAGE). --limit is the window's size (the
# real board's chip holds 4 MB).

require 'open3'
require 'optparse'
require 'tmpdir'

BITMAPS_PATH = '/rgss/bitmaps'
config = 'frames=600'
adds = []
exclude = %w[Music Sound Movie]
max_file = nil
# What the boot draws (the windowskin and the title) first, then the map frame's own material.
bitmap_dirs = %w[System Title ChipSet FaceSet CharSet GameOver Battle Monster Backdrop Picture Panorama]
bitmaps_out = nil
limit = 0x0100_0000
OptionParser.new do |o|
  o.on('--config S') { |s| config = s }
  o.on('--add S') { |s| adds << s.split(':', 2) }
  o.on('--exclude S') { |s| exclude = s.split(',') }
  o.on('--max-file N', Integer) { |n| max_file = n }
  o.on('--bitmaps S') { |s| bitmap_dirs = s.split(',') }
  o.on('--no-bitmaps') { bitmap_dirs = [] }
  o.on('--bitmaps-out FILE') { |s| bitmaps_out = s }
  o.on('--limit N', Integer) { |n| limit = n }
end.parse!
out, game = ARGV
abort 'usage: game_rom.rb OUT GAME_DIR [options]' unless out && game && File.directory?(game)

files = Dir.glob('**/*', base: game).sort.filter_map do |rel|
  path = File.join(game, rel)
  next unless File.file?(path)
  next if exclude.include?(rel.split('/').first)
  next if rel =~ /\.(exe|dll)\z/i
  next if max_file && File.size(path) > max_file

  ["/rom/#{rel}", path]
end
adds.each { |local, card| files << [card, local] }

def align(n, a) = (n + a - 1) / a * a

Decoded = Struct.new(:rel, :w, :h, :bpp, :pal, :idx)

# The palette images among +rels+ (paths under +game+), decoded.
def decode_bitmaps(game, rels)
  root = File.expand_path('../..', __dir__)
  Dir.mktmpdir('rom_bitmaps') do |dir|
    tool = File.join(dir, 'rom_bitmaps')
    system(ENV.fetch('CXX', 'c++'), '-std=c++17', '-O2', "-I#{root}/3rd/stb", "-I#{root}/include",
           "#{root}/scripts/wio/rom_bitmaps.cxx", '-o', tool, exception: true)
    input = rels.map { |r| "#{File.join(game, r)}\n" }.join
    stdout, status = Open3.capture2(tool, stdin_data: input, binmode: true)
    abort 'game_rom: rom_bitmaps failed' unless status.success?
    pos = 0
    rels.filter_map do |rel|
      ok = stdout.getbyte(pos)
      pos += 1
      next if ok.zero?

      w, h = stdout.unpack("@#{pos}V2")
      bpp = [stdout.getbyte(pos + 8), stdout.getbyte(pos + 9)]
      pal = [stdout.byteslice(pos + 10, 1024), stdout.byteslice(pos + 1034, 1024)]
      pos += 2058
      idx = stdout.byteslice(pos, w * h)
      pos += w * h
      Decoded.new(rel, w, h, bpp, pal, idx)
    end
  end
end

# The ROM_BITMAP section: header, entries sorted by path, the paths, then the
# pixel and palette blobs, each 16-aligned (the SAMD51 cache's line) and an
# identical palette stored once.
def bitmap_section(entries)
  entries = entries.sort_by(&:rel)
  names = entries.map { |e| "#{e.rel}\0".b }
  head = 16 + (entries.size * 32)
  at = head
  path_offs = names.map { |n| at.tap { at += n.bytesize } }
  blobs = +''.b
  blobs_at = head + names.sum(&:bytesize)
  placed = {}
  place = lambda do |bytes|
    placed[bytes] ||= begin
      blobs << ("\0" * ((-(blobs_at + blobs.bytesize)) % 16))
      at = blobs_at + blobs.bytesize
      blobs << bytes
      at
    end
  end
  table = entries.each_with_index.map do |e, i|
    [path_offs[i], place.call(e.idx), e.w, e.h, place.call(e.pal[0]), place.call(e.pal[1]), *e.bpp].pack('V8')
  end
  "RGSSRB01".b + [entries.size, 0].pack('V2') + table.join + names.join + blobs
end

candidates = bitmap_dirs.flat_map do |want|
  files.filter_map do |card, _|
    rel = card.delete_prefix('/rom/')
    rel if card.start_with?('/rom/') && (rel == want || rel.start_with?("#{want}/"))
  end
end.uniq
packed = []
unless candidates.empty?
  # The window's room once every file is in, less the section's own header
  # and alignment; packing an image trades its file for its pixels and a
  # possibly new pair of palettes.
  used = files.sum { |card, local| 12 + card.bytesize + 1 + align(File.size(local), 4) }
  room = limit - 20 - used - config.bytesize - 1 - (12 + BITMAPS_PATH.bytesize + 1 + 16 + 16)
  decode_bitmaps(game, candidates).each do |e|
    file = 12 + "/rom/#{e.rel}".bytesize + 1 + align(File.size(File.join(game, e.rel)), 4)
    cost = 32 + e.rel.bytesize + 1 + align(e.w * e.h, 16) + 2048 + 32 - file
    next if cost > room

    room -= cost
    packed << e
  end
end
unless packed.empty?
  section = bitmap_section(packed)
  gone = packed.to_h { |e| ["/rom/#{e.rel}", true] }
  files.reject! { |card, _| gone[card] }
  files << [BITMAPS_PATH, section]
  File.binwrite(bitmaps_out, section) if bitmaps_out
  puts "game_rom: #{packed.size} of #{candidates.size} images decoded in (#{section.bytesize} bytes)"
end

config_bytes = "#{config.tr(';', "\n")}\n".b
names = files.map { |card, _| "#{card}\0".b }
config_off = 20 + (files.size * 12) + names.sum(&:bytesize)
img = +'WIOGROM1'.b
img << [files.size, config_off, config_bytes.bytesize].pack('V3')
name_off = 20 + (files.size * 12)
data = +''.b
data_off = config_off + config_bytes.bytesize
files.each_with_index do |(card, local), i|
  bitmaps = card == BITMAPS_PATH
  data << ("\0" * ((-(data_off + data.bytesize)) % (bitmaps ? 16 : 4)))
  bytes = bitmaps ? local : File.binread(local)
  img << [name_off, data_off + data.bytesize, bytes.bytesize].pack('V3')
  name_off += names[i].bytesize
  data << bytes
end
names.each { |n| img << n }
img << config_bytes << data
abort "game_rom: #{img.bytesize} bytes is past the #{limit}-byte window" if img.bytesize > limit

File.binwrite(out, img)
puts "game_rom: #{files.size} files, #{img.bytesize} bytes -> #{out}"
