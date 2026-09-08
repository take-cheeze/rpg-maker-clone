#!/usr/bin/env ruby
# encoding: UTF-8
#
# Assert that a frame app/nano7/host/nano7_host_shim.c wrote actually shows
# real map content, not a blank/flat fill -- the pixel half of
# scripts/nano7_host_smoke.bash's claim, the same reasoning
# scripts/mz_frame_check.rb's own header explains for its PNG frames: a boot
# check that only watches control flow (did rw_open return RW_OK, did the app
# reach hb_raw_frame) can pass while nothing actually got drawn.
#
# Reads the one BMP variant nano7_host_shim.c's write_bmp24 writes: an
# uncompressed, bottom-up, 24bpp BGR888 BMP, rows padded to 4 bytes -- not a
# general BMP reader, the same "read exactly the one format the writer in
# this repo emits" scope mz_frame_check.rb's PNG reader uses.
#
# Usage: ruby scripts/nano7_host_smoke_check.rb FRAME.bmp

class Bmp
  attr_reader :width, :height, :pixels # pixels: width*height RGB 3-byte strings, row-major, top-down

  def initialize(path)
    data = File.binread(path)
    raise 'not a BMP' unless data[0, 2] == 'BM'

    data_offset = data[10, 4].unpack1('V')
    header_size = data[14, 4].unpack1('V')
    raise "unsupported BMP header size #{header_size}" unless header_size == 40

    @width = data[18, 4].unpack1('l<')
    raw_height = data[22, 4].unpack1('l<')
    bottom_up = raw_height.positive?
    @height = raw_height.abs
    planes, bitcount = data[26, 4].unpack('vv')
    compression = data[30, 4].unpack1('V')
    raise "unsupported BMP planes #{planes}" unless planes == 1
    raise "unsupported BMP bit depth #{bitcount}" unless bitcount == 24
    raise "unsupported BMP compression #{compression}" unless compression.zero?
    raise 'top-down BMPs are not supported' unless bottom_up

    row_bytes = width * 3
    row_size = row_bytes + ((4 - (row_bytes % 4)) % 4)
    @pixels = Array.new(width * height)
    (0...height).each do |y|
      row_off = data_offset + (height - 1 - y) * row_size # bottom-up -> flip to top-down
      row = data.byteslice(row_off, row_bytes)
      (0...width).each do |x|
        b, g, r = row.byteslice(x * 3, 3).bytes
        pixels[(y * width) + x] = [r, g, b]
      end
    end
  end

  # [distinct colour count, percentage of pixels that are the single most common colour]
  def census
    counts = Hash.new(0)
    pixels.each { |p| counts[p] += 1 }
    [counts.size, 100.0 * counts.values.max / pixels.size]
  end
end

path = ARGV[0]
abort 'usage: ruby scripts/nano7_host_smoke_check.rb FRAME.bmp' if path.nil?
abort "no such file: #{path}" unless File.file?(path)

frame = Bmp.new(path)
colours, dominant_pct = frame.census

# A real Nepheshel map viewport composites many chipset colours across
# several distinct tiles plus the hero sprite; a blank fill (a bug that
# reached "wrote a file" without ever compositing a tile, e.g. hb_fs_read
# failing silently, or rw_open failing and only the "no map" placeholder
# screen drawing) is one or a handful of colours dominating almost the whole
# frame. These thresholds are generous, not tuned to this one map: a genuine
# render clears them by a wide margin, and a flat fill cannot.
MIN_COLOURS = 8
MAX_DOMINANT_PCT = 90.0

ok = true
if colours < MIN_COLOURS
  warn "FAIL: only #{colours} distinct colours in #{path} (expected >= #{MIN_COLOURS}) " \
       '-- looks like a blank/placeholder frame, not a rendered map'
  ok = false
end
if dominant_pct > MAX_DOMINANT_PCT
  warn format('FAIL: %.1f%% of %s is one colour (expected <= %.1f%%) ' \
              '-- looks like a flat fill, not a rendered map', dominant_pct, path, MAX_DOMINANT_PCT)
  ok = false
end

if ok
  puts "OK: #{path} is #{frame.width}x#{frame.height}, #{colours} colours, " \
       "#{format('%.1f', dominant_pct)}% dominant"
else
  exit 1
end
