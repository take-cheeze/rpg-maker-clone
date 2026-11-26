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

require 'optparse'
require_relative 'bitmap_section'

BITMAPS_PATH = '/rgss/bitmaps'
config = 'frames=600'
adds = []
exclude = %w[Music Sound Movie]
max_file = nil
bitmap_dirs = BitmapSection::DIRS
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
  BitmapSection.decode(game, candidates).each do |e|
    file = 12 + "/rom/#{e.rel}".bytesize + 1 + align(File.size(File.join(game, e.rel)), 4)
    cost = 32 + e.rel.bytesize + 1 + align(e.w * e.h, 16) + 2048 + 32 - file
    next if cost > room

    room -= cost
    packed << e
  end
end
unless packed.empty?
  section = BitmapSection.build(packed)
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
