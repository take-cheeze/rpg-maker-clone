#!/usr/bin/env ruby
# encoding: UTF-8
#
# Assert that a screendump scripts/nano7_qemu_run.bash captured off the real
# PL110 framebuffer actually shows real map content, not a blank/flat fill
# -- the pixel half of the nano7-qemu CI job's claim, the same reasoning
# scripts/nano7_host_smoke_check.rb's own header explains for the host
# build's BMP frames (and scripts/mz_frame_check.rb's for PNG): a boot check
# that only watches UART output (did the app reach hb_raw_frame, did it print
# cycle counts) can pass while nothing actually got drawn to the screen.
#
# Reads the one PPM variant QEMU's own `screendump` monitor command writes:
# binary P6, 8 bits/channel, no comments -- not a general PPM reader.
#
# If a UART log is given as a second argument, also prints (does not assert
# on -- see docs/adr/0103 for why these numbers are a comparative signal,
# not a pass/fail threshold) the per-frame PMU cycle counts
# app/nano7/qemu/nano7_qemu_shim.c logs, so a CI run's log carries real
# numbers a human can compare across commits.
#
# Usage: ruby scripts/nano7_qemu_smoke_check.rb FRAME.ppm [uart.log]

class Ppm
  attr_reader :width, :height, :pixels # width*height RGB 3-byte strings, row-major, top-down

  def initialize(path)
    data = File.binread(path)
    raise 'not a binary PPM (P6)' unless data[0, 2] == 'P6'

    idx = 2
    tokens = []
    while tokens.size < 3
      idx += 1 while data[idx] =~ /\s/
      start = idx
      idx += 1 while data[idx] !~ /\s/
      tokens << data[start...idx]
    end
    idx += 1 # the single whitespace byte after maxval
    @width, @height, maxval = tokens.map(&:to_i)
    raise "unsupported maxval #{maxval}" unless maxval == 255
    raise 'truncated PPM' if data.bytesize < idx + (width * height * 3)

    @pixels = data.byteslice(idx, width * height * 3)
  end

  def rgb(x, y)
    pixels.byteslice(((y * width) + x) * 3, 3)
  end

  # [distinct colour count, percentage of pixels that are the single most common colour]
  def census
    counts = Hash.new(0)
    (0...height).each { |y| (0...width).each { |x| counts[rgb(x, y)] += 1 } }
    total = width * height
    [counts.size, 100.0 * counts.values.max / total]
  end
end

path = ARGV[0]
abort 'usage: ruby scripts/nano7_qemu_smoke_check.rb FRAME.ppm [uart.log]' if path.nil?
abort "no such file: #{path}" unless File.file?(path)

frame = Ppm.new(path)
colours, dominant_pct = frame.census

# Same thresholds and reasoning as scripts/nano7_host_smoke_check.rb: a real
# Nepheshel map viewport composites many chipset colours across several
# distinct tiles plus the hero sprite; a blank/placeholder screen is one or
# a handful of colours dominating almost the whole frame.
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

uart_log = ARGV[1]
if uart_log && File.file?(uart_log)
  cycles = File.readlines(uart_log).filter_map { |l| ::Regexp.last_match(1).to_i(16) if l =~ /frame=\d+ cycles=(0x[0-9a-f]+)/ }
  init_line = File.readlines(uart_log).find { |l| l.include?('init cycles=') }
  if !cycles.empty?
    puts format('cycles: init=%s frame min=%d max=%d avg=%d (n=%d, QEMU cortex-a8 TCG -- a ' \
                'comparative signal, not hardware nanoseconds, see docs/adr/0103)',
                 init_line ? init_line[/cycles=(0x[0-9a-f]+)/, 1] : '?',
                 cycles.min, cycles.max, cycles.sum / cycles.size, cycles.size)
  end
end

if ok
  puts "OK: #{path} is #{frame.width}x#{frame.height}, #{colours} colours, " \
       "#{format('%.1f', dominant_pct)}% dominant"
else
  exit 1
end
