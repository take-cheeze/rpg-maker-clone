#!/usr/bin/env ruby
# frozen_string_literal: true

# Chooses the functions QSPI_XIP keeps in internal flash (app/wio/qspi_xip_hot.txt) from instruction traces of a
# QSPI_XIP firmware: the ones that cost the most QSPI cache misses per byte of code, until the byte budget is spent.
#
# A trace is Renode's PC trace of the game (scripts/wio/renode_game.bash --trace FILE --trace-at SECONDS): one
# executed instruction's address per line. The fetches run through a model of the SAMD51's CMCC (4 KB, 4-way,
# 16-byte lines, LRU; data reads left out), and each miss on a line of a candidate function (CANDIDATES below) is
# charged to it. Traces are weighed equally, each scaled to its own total of those misses.
#
# STABLE_GLOB: a line names a function by what survives an unrelated rebuild -- its name without its parameter
# list or LTO clone suffix (.isra.N, .constprop.N, ...), with bc2cpp's hashed namespaces and the numbers it gives
# constant accessors and block bodies widened to `*` -- so it keeps matching when other code changes. A line costs the size of every QSPI
# function it matches.
#
# Usage: ruby scripts/wio/qspi_xip_hot.rb FIRMWARE.elf BUDGET_BYTES TRACE... > app/wio/qspi_xip_hot.txt
#        ruby scripts/wio/qspi_xip_hot.rb --check FIRMWARE.elf [HOT_LIST]
#   --check lists the lines that match no function of the ELF (HOT_LIST: app/wio/qspi_xip_hot.txt) and fails when
#   more than STALE_LIMIT of them do: the list needs new traces.
#   NM (default PlatformIO's arm-none-eabi-nm) lists the ELF's symbols.
require 'open3'

QSPI = (0x0400_0000...0x0440_0000)
SETS = 64
WAYS = 4
STALE_LIMIT = 0.25

def symbols(elf)
  nm = ENV.fetch('NM', File.join(Dir.home, '.platformio/packages/toolchain-gccarmnoneeabi/bin/arm-none-eabi-nm'))
  out, err, st = Open3.capture3(nm, '-S', '--defined-only', elf)
  abort "nm failed: #{err}" unless st.success?
  out.lines.filter_map do |l|
    addr, size, type, name = l.split
    # Veneers are the linker's, not a section a placement line can name.
    next unless name && type.match?(/\A[tTwW]\z/) && !name.end_with?('_veneer')

    { name: name, addr: addr.to_i(16) & ~1, size: size.to_i(16), weight: 0.0 }
  end
end

# The <length><identifier> at +i+ of +s+: [identifier, the index after it], or nil.
def source_name(s, i)
  m = s.match(/\G(\d+)/, i) or return nil
  n = m[1].to_i
  ident = s[m.end(0), n]
  ident&.size == n ? [ident, m.end(0) + n] : nil
end

# An identifier as STABLE_GLOB matches it: nil for a hashed namespace.
def widen(ident)
  return nil if ident.match?(/\Abc2cpp_cs_\h+\z/)

  ident.sub(/\A(bc2cpp_(?:cconst|mcnst|rt|const_scope)_)\d+\z/, '\1*').gsub(/(_(?:block_fallback|inline)_)\d+/, '\1*')
end

def mangled(ident)
  return '*' unless ident
  return "*#{ident}" if ident.include?('*')

  "#{ident.size}#{ident}"
end

# See STABLE_GLOB.
def stable_glob(name)
  base = name.sub(/\.(?:isra|constprop|part|lto_priv|cold)\.\d+.*\z/, '')
  if (m = base.match(/\A_Z(L?)(?=\d)/))
    ident, = source_name(base, m.end(0))
    return name unless ident

    return "_Z#{m[1]}#{mangled(widen(ident))}*".squeeze('*')
  end
  if base.start_with?('_ZN')
    i = 3
    parts = []
    while (r = source_name(base, i))
      parts << widen(r[0])
      i = r[1]
    end
    return name if parts.empty? || base[i] != 'E'

    return "_ZN#{parts.map { |p| mangled(p) }.join}E*".squeeze('*')
  end
  # A C name is stable; its clones keep a suffix.
  base == name ? name : "#{base}.*"
end

def check(elf, list)
  names = symbols(elf).map { |f| f[:name] }
  globs = File.foreach(list).filter_map do |l|
    where, glob = l.split('#', 2)[0].split
    glob if where == 'internal'
  end
  stale = globs.reject { |g| names.any? { |n| File.fnmatch(g, n) } }
  stale.each { |g| puts "stale: #{g}" }
  puts format('qspi_xip_hot: %d of %d lines match no function of %s', stale.size, globs.size, File.basename(elf))
  exit 1 if stale.size > globs.size * STALE_LIMIT
end

# scripts/wio/qspi_xip_hot_check.rb loads the definitions above.
return unless __FILE__ == $PROGRAM_NAME

if ARGV[0] == '--check'
  abort "usage: #{$PROGRAM_NAME} --check FIRMWARE.elf [HOT_LIST]" unless ARGV[1]
  check(ARGV[1], ARGV[2] || File.expand_path('../../app/wio/qspi_xip_hot.txt', __dir__))
  exit 0
end

elf, budget, *traces = ARGV
abort "usage: #{$PROGRAM_NAME} FIRMWARE.elf BUDGET_BYTES TRACE..." if traces.empty?
budget = Integer(budget)
# CANDIDATES: what would run from QSPI without this list -- what does, and what qspi_xip_placement.txt's `text` lines
# send there but the list in the traced build kept internal -- so a trace of a build with a list chooses as one without.
text = File.foreach(File.expand_path('../../app/wio/qspi_xip_placement.txt', __dir__)).filter_map do |l|
  where, glob = l.split('#', 2)[0].split
  glob if where == 'text'
end
funcs = symbols(elf).select do |f|
  f[:size].positive? && (QSPI.cover?(f[:addr]) || text.any? { |g| File.fnmatch(g, f[:name]) })
end
funcs.sort_by! { |f| f[:addr] }
starts = funcs.map { |f| f[:addr] }

# Cache misses per 16-byte line of one trace.
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
    per_line[line] += 1
  end
  per_line
end

traces.each do |path|
  owned = misses(path).filter_map do |line, n|
    i = starts.bsearch_index { |a| a > (line << 4) }
    f = funcs[(i || funcs.size) - 1]
    [f, n] if f && (line << 4) < f[:addr] + f[:size]
  end
  total = owned.sum { |_, n| n }.to_f
  warn "qspi_xip_hot: #{File.basename(path)}: #{total.to_i} line misses in candidate code"
  owned.each { |f, n| f[:weight] += n / total } unless total.zero?
end

# One candidate per glob of a function the traces reached, costing every QSPI function the glob matches.
globs = funcs.select { |f| f[:weight].positive? }.map { |f| stable_glob(f[:name]) }.uniq
groups = globs.map do |glob|
  members = funcs.select { |f| File.fnmatch(glob, f[:name]) }
  { glob: glob, size: members.sum { |f| f[:size] }, weight: members.sum { |f| f[:weight] } }
end

used = 0
share = 0.0
puts '# QSPI_XIP: functions kept in internal flash, chosen by scripts/wio/qspi_xip_hot.rb from Renode traces of the'
puts "# game (#{traces.map { |t| File.basename(t) }.join(', ')}; #{budget}-byte budget)."
groups.sort_by { |g| -g[:weight] / g[:size] }.each do |g|
  next if used + g[:size] > budget

  used += g[:size]
  share += g[:weight]
  puts "internal #{g[:glob]}"
end
warn format('qspi_xip_hot: %d of %d bytes keep %.0f%% of the traces\' QSPI misses internal', used, budget,
            share * 100 / traces.size)
