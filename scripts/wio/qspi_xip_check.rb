#!/usr/bin/env ruby
# frozen_string_literal: true

# QSPI_XIP check of a linked Wio firmware (app/wio/qspi_xip.ld, app/wio/qspi_xip.py,
# app/wio/src/wio_qspi_xip.cxx):
#   1. the internal-flash image fits the 496 KB after the UF2 bootloader, and the QSPI image ends below the game ROM;
#   2. the QSPI image header in the ELF (the bytes firmware_qspi.bin carries) has the magic, this ELF's build-id, the
#      image length and the CRC the boot check computes;
#   3. the unwind index (in QSPI) is sorted by address across both regions, as the unwinder's binary search needs;
#   4. nothing that runs before the window opens, or while a bad image is being reported, reaches QSPI: the
#      direct-call closure (veneers followed) of Reset_Handler up to main, SystemInit, init, SysTick_Handler,
#      __libc_init_array and the .preinit_array step, and that of every .init_array constructor and
#      wio_qspi_xip_require short of the mruby API (no VM exists before setup() opens one), has no
#      function in QSPI and no literal naming QSPI data (a function's address may be taken: constructors register
#      the compiled methods), throws not followed. main calls init then __libc_init_array first,
#      .preinit_array is the step alone, and setup calls wio_qspi_xip_require first. Indirect calls there are
#      counted: function pointers the check cannot follow.
#
# Usage: ruby scripts/wio/qspi_xip_check.rb FIRMWARE.elf [TOOL_PREFIX]
#   TOOL_PREFIX defaults to PlatformIO's arm-none-eabi- toolchain.
require 'open3'
require 'set'
require 'zlib'

FLASH_START = 0x0000_4000
FLASH_END = 0x0008_0000
QSPI_START = 0x0400_0000
QSPI_END = 0x0440_0000
MAGIC = 0x5049_5857 # WIO_QSPI_MAGIC
HEADER_SIZE = 32
BLOCK = 256
ROOTS = %w[SystemInit init SysTick_Handler __libc_init_array].freeze
# A throw (and the unwinder reading the index in QSPI) out of boot code ends the program whatever the image holds,
# so the walk does not follow one.
THROW = /\A(?:_ZSt\d+__throw_|__cxa_(?:re)?throw\z|__cxa_end_cleanup\z|_Unwind_Resume\z|_ZSt9terminatev\z|abort\z)/
PREINIT = '_ZN12_GLOBAL__N_17preinitEv'
MRUBY = /\Amrb_/

elf = ARGV[0]
abort "usage: #{$PROGRAM_NAME} FIRMWARE.elf [TOOL_PREFIX]" unless elf && File.file?(elf)
prefix = ARGV[1] || File.join(Dir.home, '.platformio/packages/toolchain-gccarmnoneeabi/bin/arm-none-eabi-')
errors = []

def run(*cmd)
  out, err, st = Open3.capture3(*cmd)
  abort "#{cmd.join(' ')} failed: #{err}" unless st.success?
  out
end

def qspi?(addr) = addr >= QSPI_START && addr < QSPI_END

bytes = File.binread(elf)
shoff = bytes.unpack1('V', offset: 0x20)
shentsize, shnum, shstrndx = bytes.unpack('vvv', offset: 0x2e)
raw = Array.new(shnum) { |i| bytes.unpack('V10', offset: shoff + (i * shentsize)) }
strtab = raw[shstrndx][4]
Section = Struct.new(:name, :type, :flags, :addr, :offset, :size)
sections = raw.map do |r|
  Section.new(bytes[strtab + r[0]...bytes.index("\0", strtab + r[0])], r[1], r[2], r[3], r[4], r[5])
end
by_name = sections.to_h { |s| [s.name, s] }
body = ->(s) { bytes.byteslice(s.offset, s.size) }
alloc = sections.select { |s| s.flags.anybits?(2) && s.size.positive? }

syms = run("#{prefix}nm", elf).lines.map(&:split).select { |f| f.size == 3 }
sym = syms.to_h { |a, _, n| [n, a.to_i(16)] }

# 1. Sizes, from the load addresses: .data (and any other initialised RAM) comes out of internal flash too.
data = by_name['.data']
phoff = bytes.unpack1('V', offset: 0x1c)
phentsize, phnum = bytes.unpack('vv', offset: 0x2a)
loads = Array.new(phnum) { |i| bytes.unpack('V8', offset: phoff + (i * phentsize)) }.select { |ph| ph[0] == 1 }
flash_end = loads.filter_map { |ph| ph[3] + ph[4] if ph[3] >= FLASH_START && ph[3] < FLASH_END }.push(FLASH_START).max
used = flash_end - FLASH_START
errors << format('internal flash: %d bytes, over the %d after the bootloader', used, FLASH_END - FLASH_START) if flash_end > FLASH_END
in_qspi = alloc.select { |s| qspi?(s.addr) }
qspi_end = (in_qspi.map { |s| s.addr + s.size } + [QSPI_START]).max
rom = sym['__wio_game_rom_base']
errors << 'no __wio_game_rom_base: not a qspi_xip.ld link' unless rom
errors << format('QSPI image ends at 0x%x, past the game ROM at 0x%x', qspi_end, rom) if rom && qspi_end > rom
errors << 'QSPI sections without contents' if in_qspi.any? { |s| s.type == 8 } # NOBITS
# Everything in QSPI but the code is data (string literals have no symbol, so by section).
qspi_data = in_qspi.reject { |s| s.name == '.qspi_text' }.map { |s| s.addr...(s.addr + s.size) }

# 2. The header.
header = by_name['.qspi_header']
note = by_name['.note.gnu.build-id']
if header && note && header.addr == QSPI_START
  image = "\0".b * (qspi_end - QSPI_START)
  in_qspi.each { |s| image[s.addr - QSPI_START, s.size] = body.call(s) }
  magic, length, crc, stride = image.unpack('V4')
  namesz = body.call(note).unpack1('V')
  build_id = body.call(note).byteslice(12 + ((namesz + 3) & ~3), 16)
  payload = image.byteslice(HEADER_SIZE..)
  blocks = (payload.bytesize + BLOCK - 1) / BLOCK
  sum = 0
  blocks.times { |i| sum = Zlib.crc32(payload.byteslice(i * stride % blocks * BLOCK, BLOCK), sum) }
  errors << format('header magic 0x%08x', magic) unless magic == MAGIC
  errors << 'header build-id is not this ELF\'s' unless image.byteslice(16, 16) == build_id
  errors << "header length #{length}, image #{payload.bytesize}" unless length == payload.bytesize
  errors << format('header CRC 0x%08x, image 0x%08x', crc, sum) unless crc == sum
  errors << "header stride #{stride} is not coprime with #{blocks} blocks" unless blocks < 2 || stride.gcd(blocks) == 1
else
  errors << 'no .qspi_header at the window start, or no build-id note'
end

# 3. The unwind index.
exidx = by_name['.ARM.exidx']
if exidx
  starts = body.call(exidx).unpack('V*').each_slice(2).each_with_index.map do |(w0, _), i|
    off = w0 & 0x7fff_ffff
    off -= 0x8000_0000 if off.anybits?(0x4000_0000)
    (exidx.addr + (i * 8) + off) & 0xffff_ffff
  end
  bad = starts.each_cons(2).find_index { |a, b| b < a }
  errors << format('.ARM.exidx is not sorted (entry %d)', bad + 1) if bad
  errors << '.ARM.exidx is not in QSPI' unless qspi?(exidx.addr)
else
  errors << 'no .ARM.exidx'
end

# 4. What runs before the window opens or while a bad image is reported.
funcs = {}
calls = Hash.new { |h, k| h[k] = [] }
indirect = Hash.new(0)
words = Hash.new { |h, k| h[k] = [] }
current = nil
run("#{prefix}objdump", '-d', '--no-show-raw-insn', elf).each_line do |line|
  if (m = line.match(/\A([0-9a-f]+) <([^>]+)>:/))
    current = m[2]
    funcs[m[1].to_i(16)] = current
  elsif current && (m = line.match(/\A\s*[0-9a-f]+:\s+(b(?:l|lx)?(?:eq|ne|cs|cc|hs|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|al)?(?:\.w|\.n)?|cbn?z)\s+(?:r\d+, )?([0-9a-f]+) <([^>+]+)/))
    calls[current] << m[3]
  elsif current && line.match?(/\A\s*[0-9a-f]+:\s+(blx|bx|mov(?:\.w)?\s+pc,|ldr(?:\.w)?\s+pc,)\s*(r\d+|ip|sb|sl|fp|lr|\[)/) &&
        !line.match?(/\sbx\s+lr\b/)
    indirect[current] += 1
  elsif current && (m = line.match(/\A\s*[0-9a-f]+:\s+\.word\s+0x([0-9a-f]+)/))
    words[current] << m[1].to_i(16)
  end
end
name_at = ->(addr) { funcs[addr & ~1] }
ctors = %w[__preinit_array __init_array].flat_map do |arr|
  lo = sym["#{arr}_start"]
  hi = sym["#{arr}_end"]
  next [] unless lo && hi && data

  body.call(data).byteslice(lo - data.addr, hi - lo).unpack('V*').map { |a| [arr, a] }
end
preinit = ctors.select { |arr, _| arr == '__preinit_array' }.map { |_, a| name_at.call(a) }
errors << ".preinit_array is #{preinit.inspect}, not the QSPI step alone" unless preinit == [PREINIT]
init = ctors.select { |arr, _| arr == '__init_array' }.map(&:last)
init.each { |a| errors << format('.init_array names 0x%x in QSPI', a) if qspi?(a & ~1) }
first = ->(f) { calls[f].first(2) }
errors << "main calls #{first.call('main').join(', ')} first, not init then __libc_init_array" unless first.call('main') == %w[init __libc_init_array]
errors << "setup calls #{calls['setup'].first} first, not wio_qspi_xip_require" unless calls['setup'].first == 'wio_qspi_xip_require'

addr_of = funcs.invert
seen = Set.new
parent = {}
path = lambda do |f|
  chain = [f]
  chain << parent[chain.last] while parent[chain.last] && chain.size < 30
  chain.reverse.join(' -> ')
end
# Walks the direct calls from +roots+, past veneers, stopping at +stop+, and reports what lands in or reads QSPI.
walk = lambda do |roots, stop|
  queue = roots.dup
  reached = []
  until queue.empty?
    f = queue.shift
    next if THROW.match?(f) || stop&.match?(f)
    next unless seen.add?(f)

    reached << f
    # Reset_Handler calls main last; main's first two calls are roots.
    succ = f == 'Reset_Handler' ? calls[f] - ['main'] : calls[f]
    # A long-branch veneer jumps to the address in its literal.
    succ += words[f].filter_map { |w| name_at.call(w) } if f.end_with?('_veneer')
    succ.each do |g|
      parent[g] ||= f unless seen.include?(g)
      queue << g
    end
  end
  reached.each do |f|
    addr = addr_of[f]
    errors << "#{path.call(f)}: in QSPI" if addr && qspi?(addr)
    # The QSPI step is the one function that reads the window, after opening it.
    next if f == PREINIT

    words[f].select { |w| qspi_data.any? { |r| r.cover?(w) } }.each do |w|
      errors << "#{path.call(f)}: names QSPI data at 0x#{w.to_s(16)}"
    end
  end
end
# Before the window opens, everything.
walk.call(['Reset_Handler', PREINIT] + ROOTS, nil)
# The constructors and the report run before setup() opens a VM, so no mruby function runs there (a malloc hook may
# call one once a VM exists).
walk.call(init.filter_map { |a| name_at.call(a) } + ['wio_qspi_xip_require'], MRUBY)
veneers = funcs.values.count { |n| n.end_with?('_veneer') }
qspi_funcs = funcs.count { |a, _| qspi?(a) }
puts format('qspi_xip_check: internal flash %d of %d bytes, QSPI image %d bytes (game ROM at 0x%x)',
            used, FLASH_END - FLASH_START, qspi_end - QSPI_START, rom || 0)
puts "  #{qspi_funcs} functions in QSPI, #{veneers} long-branch veneers; #{seen.size} functions run before the " \
     "window opens or while a bad image is reported (#{init.size} constructors), " \
     "#{seen.sum { |f| indirect[f] }} indirect calls among them"
if errors.empty?
  puts 'qspi_xip_check: PASS'
else
  puts errors.first(40)
  puts "qspi_xip_check: FAIL (#{errors.size})"
  exit 1
end
