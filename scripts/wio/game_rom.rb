#!/usr/bin/env ruby
# frozen_string_literal: true

# Packs a game directory into the image the wio_renode_game firmware reads
# (layout: app/wio/src/wio_game_rom.h). Files land under /rom/ (GAME_DIR);
# --add puts one more file at an absolute path (the font, /gothic.bin).
#
#   scripts/wio/game_rom.rb OUT GAME_DIR [--config 'k=v;k=v'] [--add LOCAL:PATH]...
#                           [--exclude DIR,DIR] [--max-file BYTES]
#
# Audio, Movie and the Windows binaries are left out by default: the Wio
# build plays no sound and the 16 MB window has to hold the rest.

require 'optparse'

LIMIT = 0x0100_0000
config = 'frames=600'
adds = []
exclude = %w[Music Sound Movie]
max_file = nil
OptionParser.new do |o|
  o.on('--config S') { |s| config = s }
  o.on('--add S') { |s| adds << s.split(':', 2) }
  o.on('--exclude S') { |s| exclude = s.split(',') }
  o.on('--max-file N', Integer) { |n| max_file = n }
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

config_bytes = "#{config.tr(';', "\n")}\n".b
names = files.map { |card, _| "#{card}\0".b }
config_off = 20 + (files.size * 12) + names.sum(&:bytesize)
img = +'WIOGROM1'.b
img << [files.size, config_off, config_bytes.bytesize].pack('V3')
name_off = 20 + (files.size * 12)
data = +''.b
data_off = config_off + config_bytes.bytesize
files.each_with_index do |(_, local), i|
  data << ("\0" * ((-(data_off + data.bytesize)) % 4))
  bytes = File.binread(local)
  img << [name_off, data_off + data.bytesize, bytes.bytesize].pack('V3')
  name_off += names[i].bytesize
  data << bytes
end
names.each { |n| img << n }
img << config_bytes << data
abort "game_rom: #{img.bytesize} bytes is past the #{LIMIT}-byte window" if img.bytesize > LIMIT

File.binwrite(out, img)
puts "game_rom: #{files.size} files, #{img.bytesize} bytes -> #{out}"
