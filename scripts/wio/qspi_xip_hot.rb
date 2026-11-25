#!/usr/bin/env ruby
# frozen_string_literal: true

# Chooses the functions QSPI_XIP keeps in internal flash (app/wio/qspi_xip_hot.txt) from instruction traces of a
# QSPI_XIP firmware: the ones that cost the most QSPI cache misses per byte of code, until the byte budget is spent.
#
# A trace is Renode's PC trace of the game (scripts/wio/renode_game.bash --trace FILE --trace-at SECONDS): one
# executed instruction's address per line. The fetches run through a model of the SAMD51's CMCC (4 KB, 4-way,
# 16-byte lines, LRU; data reads left out), and each miss on a QSPI line is charged to the function there. Traces
# are weighed equally, each scaled to its own total of QSPI misses.
#
# Usage: ruby scripts/wio/qspi_xip_hot.rb FIRMWARE.elf BUDGET_BYTES TRACE... > app/wio/qspi_xip_hot.txt
#   NM (default PlatformIO's arm-none-eabi-nm) lists the ELF's symbols.
require 'open3'

QSPI = (0x0400_0000...0x0440_0000)
SETS = 64
WAYS = 4

elf, budget, *traces = ARGV
abort "usage: #{$PROGRAM_NAME} FIRMWARE.elf BUDGET_BYTES TRACE..." if traces.empty?
budget = Integer(budget)
nm = ENV.fetch('NM', File.join(Dir.home, '.platformio/packages/toolchain-gccarmnoneeabi/bin/arm-none-eabi-nm'))
out, err, st = Open3.capture3(nm, '-S', '--defined-only', elf)
abort "nm failed: #{err}" unless st.success?
funcs = out.lines.filter_map do |l|
  addr, size, type, name = l.split
  # Veneers are the linker's, not a section a placement line can name.
  next unless name && type.match?(/\A[tTwW]\z/) && !name.end_with?('_veneer')

  addr = addr.to_i(16) & ~1
  { name: name, addr: addr, size: size.to_i(16), weight: 0.0 } if QSPI.cover?(addr) && size.to_i(16).positive?
end
funcs.sort_by! { |f| f[:addr] }
starts = funcs.map { |f| f[:addr] }

# QSPI misses per 16-byte line of one trace.
def misses(path)
  tags = Array.new(SETS) { [] } # most recently used last
  per_line = Hash.new(0)
  last = nil
  File.foreach(path) do |l|
    line = l.to_i(16) >> 4
    next if line == last

    last = line
    set = tags[line % SETS]
    if (i = set.index(line))
      set.push(set.delete_at(i))
      next
    end
    set.shift if set.size == WAYS
    set.push(line)
    per_line[line] += 1 if QSPI.cover?(line << 4)
  end
  per_line
end

traces.each do |path|
  per_line = misses(path)
  total = per_line.values.sum.to_f
  warn "qspi_xip_hot: #{File.basename(path)}: #{total.to_i} QSPI line misses"
  next if total.zero?

  per_line.each do |line, n|
    i = starts.bsearch_index { |a| a > (line << 4) }
    f = funcs[(i || funcs.size) - 1]
    f[:weight] += n / total if f && (line << 4) < f[:addr] + f[:size]
  end
end

used = 0
share = 0.0
puts '# QSPI_XIP: functions kept in internal flash, chosen by scripts/wio/qspi_xip_hot.rb from Renode traces of the'
puts "# game (#{traces.map { |t| File.basename(t) }.join(', ')}; #{budget}-byte budget)."
funcs.select { |f| f[:weight].positive? }.sort_by { |f| -f[:weight] / f[:size] }.each do |f|
  next if used + f[:size] > budget

  used += f[:size]
  share += f[:weight]
  puts "internal #{f[:name]}"
end
warn format('qspi_xip_hot: %d of %d bytes keep %.0f%% of the traces\' QSPI misses internal', used, budget,
            share * 100 / traces.size)
