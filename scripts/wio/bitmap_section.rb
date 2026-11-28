# frozen_string_literal: true

# The ROM_BITMAP section (mruby-rgss/src/lib.cxx) that scripts/wio/game_rom.rb puts in the game image and
# scripts/wio/sd_bitmaps.rb writes to the card, and the decode of its images.
require 'open3'
require 'tmpdir'
require 'zlib'

module BitmapSection
  # What the boot draws (the windowskin and the title) first, then the map frame's own material.
  DIRS = %w[System Title ChipSet FaceSet CharSet GameOver Battle Monster Backdrop Picture Panorama].freeze

  Decoded = Struct.new(:rel, :w, :h, :bpp, :pal, :idx)

  module_function

  # The palette images among +rels+ (paths under +game+), decoded with the runtime's own decoders
  # (scripts/wio/rom_bitmaps.cxx).
  def decode(game, rels)
    root = File.expand_path('../..', __dir__)
    Dir.mktmpdir('rom_bitmaps') do |dir|
      tool = File.join(dir, 'rom_bitmaps')
      system(ENV.fetch('CXX', 'c++'), '-std=c++17', '-O2', "-I#{root}/3rd/stb", "-I#{root}/include",
             "#{root}/scripts/wio/rom_bitmaps.cxx", '-o', tool, exception: true)
      input = rels.map { |r| "#{File.join(game, r)}\n" }.join
      stdout, status = Open3.capture2(tool, stdin_data: input, binmode: true)
      abort 'bitmap_section: rom_bitmaps failed' unless status.success?
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

  # Header, entries sorted by path, the paths, then the pixel and palette blobs, each 16-aligned (the SAMD51 cache's
  # line) and an identical palette stored once. With +checksum+ the header's fourth word is the CRC-32 of the whole
  # section with that word zero, then of +salt+ (how the Wio's QSPI cache tells one card's game from another), else 0.
  def build(entries, checksum: false, salt: ''.b)
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
    section = 'RGSSRB01'.b + [entries.size, 0].pack('V2') + table.join + names.join + blobs
    return section unless checksum

    # Never 0: the cache reads 0 as no checksum.
    section[12, 4] = [Zlib.crc32(salt, Zlib.crc32(section)).nonzero? || 1].pack('V')
    section
  end
end
