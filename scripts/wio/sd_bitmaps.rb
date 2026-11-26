#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the pack of a game's palette images, decoded, that the Wio firmware copies into its QSPI cache from the
# microSD card (IMAGE_CACHE, app/wio/src/wio_image_cache.h) instead of decoding their files into the heap:
#
#   scripts/wio/sd_bitmaps.rb GAME_DIR [OUT]
#
# GAME_DIR is the game folder as it is on the card (the card's /rpg2k); OUT defaults to GAME_DIR/wio_bitmaps.bin,
# where the firmware looks. Images that are not palette images are left to their files. Rebuild the pack whenever the
# game's images change: the firmware cannot tell a stale one.
require_relative 'bitmap_section'

game, out = ARGV
abort 'usage: sd_bitmaps.rb GAME_DIR [OUT]' unless game && File.directory?(game) && ARGV.size <= 2
out ||= File.join(game, 'wio_bitmaps.bin')

rels = BitmapSection::DIRS.flat_map do |dir|
  Dir.glob('**/*', base: File.join(game, dir)).sort.filter_map do |rel|
    path = File.join(dir, rel)
    path if File.file?(File.join(game, path))
  end
end
decoded = BitmapSection.decode(game, rels)
abort "sd_bitmaps: no palette image in #{game}" if decoded.empty?
pack = BitmapSection.build(decoded, checksum: true)
File.binwrite(out, pack)
puts format('sd_bitmaps: %d of %d images, %d bytes (crc %08x) -> %s',
            decoded.size, rels.size, pack.bytesize, pack.unpack1('@12V'), out)
