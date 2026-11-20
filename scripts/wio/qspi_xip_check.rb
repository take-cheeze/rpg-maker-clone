# frozen_string_literal: true

# QSPI_XIP check for a linked `wio` firmware (app/wio/qspi_xip.ld, app/wio/src/wio_qspi_xip.c):
#   1. the linker script's member names (libmruby.a's register.o and *_compiled_gen_shard*.o) are the *-compiled
#      gems' objects and nothing else in the wio libmruby build;
#   2. every code, read-only and unwind input section of those members is in the QSPI region, and nothing else is;
#      Every output section in the QSPI region has contents, so the image (qspi_image.py) is all of it.
#   3. nothing reachable before the XIP window opens lies in the QSPI region or reads it: the direct-call closure of
#      Reset_Handler (up to main), SystemInit, init, SysTick_Handler, the preinit step and __libc_init_array, with
#      main calling init and then __libc_init_array first, and .preinit_array holding the preinit step alone.
#      Indirect calls in that closure are listed: each is a function pointer the check cannot follow.
#
# Usage: ruby scripts/wio/qspi_xip_check.rb FIRMWARE.elf FIRMWARE.map WIO_MRUBY_BUILD_DIR/wio [OBJDUMP_PREFIX]
require 'open3'
require 'set'

QSPI_START = 0x0400_0000
QSPI_END = 0x0440_0000
MEMBER = /\A(?:register|\w+_compiled_gen_shard\d+)\.o\z/
PLACED = /\A\.(?:text|rodata|ARM\.extab|gnu\.linkonce\.armextab)/
ROOTS = %w[SystemInit init SysTick_Handler wio_qspi_xip_preinit __libc_init_array].freeze

elf, map, build_dir, prefix = ARGV
abort "usage: #{$PROGRAM_NAME} FIRMWARE.elf FIRMWARE.map WIO_BUILD_DIR [OBJDUMP_PREFIX]" unless elf && map && build_dir
prefix ||= 'arm-none-eabi-'
errors = []

def run(*cmd)
  out, err, st = Open3.capture3(*cmd)
  abort "#{cmd.join(' ')} failed: #{err}" unless st.success?
  out
end

def qspi?(addr) = addr >= QSPI_START && addr < QSPI_END

# 1. Member names.
Dir["#{build_dir}/**/*.o"].each do |path|
  next unless MEMBER.match?(File.basename(path))
  next if path.include?('-compiled/')

  errors << "#{path}: a libmruby.a member qspi_xip.ld places in QSPI, outside the *-compiled gems"
end

# 2. Placement, from the map's input-section lines (a long section name wraps onto its own line).
pending = nil
placed = 0
in_map = false # the input sections before "Linker script and memory map" are the discarded ones
File.foreach(map, encoding: 'BINARY') do |line|
  in_map ||= line.start_with?('Linker script and memory map')
  next unless in_map

  if (m = line.match(/\A (\.\S+)\s*\z/))
    pending = m[1]
    next
  end
  m = line.match(/\A (\.\S+)?\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S+)/)
  name = m && (m[1] || pending)
  pending = nil
  next unless m && name && m[3].to_i(16).positive?

  addr = m[2].to_i(16)
  member = m[4][/libmruby\.a\(([^)]+)\)\z/, 1]
  compiled = member && MEMBER.match?(member)
  if compiled && PLACED.match?(name)
    placed += 1
    errors << "#{member} #{name} at 0x#{addr.to_s(16)}: not in QSPI" unless qspi?(addr)
  elsif qspi?(addr) && !name.start_with?('.ARM.exidx', '.qspi_header') && m[4] != 'linker' # long-branch stubs
    errors << "#{m[4]} #{name} at 0x#{addr.to_s(16)}: in QSPI but not a compiled gem's"
  end
end
errors << 'no compiled-gem input section found in the map' if placed.zero?

# The QSPI image is the output sections there, byte for byte from 0x04000000: each must carry contents.
headers = run("#{prefix}objdump", '-h', elf).lines
headers.each_with_index do |line, i|
  f = line.split
  next unless f.size >= 4 && f[0].match?(/\A\d+\z/) && qspi?(f[3].to_i(16))

  errors << "#{f[1]}: a QSPI section without contents (the image would not hold it)" unless headers[i + 1].to_s.include?('CONTENTS')
end

# 3. What runs before the window opens.
funcs = {} # start address => name
calls = Hash.new { |h, k| h[k] = Set.new }
indirect = Hash.new { |h, k| h[k] = [] }
words = Hash.new { |h, k| h[k] = [] }
order = Hash.new { |h, k| h[k] = [] }
current = nil
run("#{prefix}objdump", '-d', '--no-show-raw-insn', elf).each_line do |line|
  if (m = line.match(/\A([0-9a-f]+) <([^>]+)>:/))
    current = m[2]
    funcs[m[1].to_i(16)] = current
  elsif current && (m = line.match(/\A\s*[0-9a-f]+:\s+(b(?:l|lx)?(?:eq|ne|cs|cc|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|al)?(?:\.w|\.n)?)\s+([0-9a-f]+) <([^>+]+)/))
    calls[current] << m[3]
    order[current] << m[3] if m[1].start_with?('bl')
  elsif current && (m = line.match(/\A\s*[0-9a-f]+:\s+(blx|bx)\s+(r\d+|ip|sb|sl|fp)\b/))
    indirect[current] << m[2]
  elsif current && (m = line.match(/\A\s*[0-9a-f]+:\s+\.word\s+0x([0-9a-f]+)/))
    words[current] << m[1].to_i(16)
  end
end
addr_of = funcs.to_h { |a, n| [n, a] }

main_calls = order['main'].first(2)
errors << "main calls #{main_calls.join(', ')} first, not init then __libc_init_array" unless main_calls == %w[init __libc_init_array]
syms = run("#{prefix}nm", elf).lines.map(&:split).select { |f| f.size == 3 }
preinit = syms.select { |_, _, n| n.start_with?('__preinit_array_') }.to_h { |a, _, n| [n, a.to_i(16)] }
qspi_syms = syms.to_set { |a, _, _| a.to_i(16) & ~1 }.select { |a| qspi?(a) }.to_set
size = preinit.fetch('__preinit_array_end', 0) - preinit.fetch('__preinit_array_start', 0)
errors << ".preinit_array holds #{size / 4} entries, not the preinit step alone" unless size == 4

seen = Set.new
parent = {}
queue = ['Reset_Handler'] + ROOTS
until queue.empty?
  f = queue.shift
  next unless seen.add?(f)

  # Reset_Handler calls main last; main runs init and __libc_init_array (roots) before anything else.
  (f == 'Reset_Handler' ? calls[f] - ['main'] : calls[f]).each do |g|
    parent[g] ||= f unless seen.include?(g)
    queue << g
  end
end
path = lambda do |f|
  chain = [f]
  chain << parent[chain.last] while parent[chain.last] && chain.size < 30
  chain.reverse.join(' -> ')
end
seen.each do |f|
  addr = addr_of[f]
  errors << "#{path.call(f)}: runs before the XIP window opens but is in QSPI" if addr && qspi?(addr)
  # A literal naming a QSPI symbol: a veneer or an address the code may jump to or read. The preinit step is the
  # one function that reads the window, after opening it.
  next if f == 'wio_qspi_xip_preinit'

  words[f].select { |w| qspi_syms.include?(w & ~1) }.each do |w|
    errors << "#{path.call(f)}: runs before the XIP window opens and names 0x#{w.to_s(16)} in QSPI"
  end
end
listed = seen.select { |f| indirect[f].any? }.sort
puts "qspi_xip_check: #{placed} compiled-gem input sections in QSPI; #{seen.size} functions run before the window opens"
puts "  indirect calls there (function pointers, not followed): #{listed.map { |f| "#{f}(#{indirect[f].size})" }.join(', ')}" unless listed.empty?
if errors.empty?
  puts 'qspi_xip_check: PASS'
else
  puts errors.first(40)
  puts "qspi_xip_check: FAIL (#{errors.size})"
  exit 1
end
