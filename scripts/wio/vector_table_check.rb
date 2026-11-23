#!/usr/bin/env ruby
# frozen_string_literal: true

# Static boot check of a linked Wio firmware ELF: the SAMD51 reads its initial
# SP and Reset_Handler from the vector table at the application start, so an
# image that links at a plausible size can still not boot (an LTO link once
# dropped exception_table, which only the linker script's KEEP references).
#
# usage: vector_table_check.rb FIRMWARE.elf [APP_START]   (APP_START default 0x4000, after the UF2 bootloader)

APP_START = Integer(ARGV[1] || '0x4000')
RAM = (0x2000_0000..0x2003_0000) # 192 KB; the initial SP may equal the top
CORE_VECTORS = 16
SYSTICK = 15

# Minimal ELF32 little-endian reader: sections and the symbol table.
class Elf32
  Section = Struct.new(:name, :type, :flags, :addr, :offset, :size, :link)
  Symbol = Struct.new(:name, :value, :size, :type, :bind, :shndx)

  attr_reader :sections, :symbols

  def initialize(path)
    @bytes = File.binread(path)
    raise "#{path}: not an ELF32 little-endian file" unless @bytes[0, 4] == "\x7fELF".b && @bytes.getbyte(4) == 1 &&
                                                            @bytes.getbyte(5) == 1

    shoff = u32(0x20)
    shentsize, shnum, shstrndx = @bytes[0x2e, 6].unpack('v3')
    raw = Array.new(shnum) { |i| @bytes[shoff + (i * shentsize), 40].unpack('V10') }
    names = raw[shstrndx][4]
    @sections = raw.map do |r|
      Section.new(cstr(names + r[0]), r[1], r[2], r[3], r[4], r[5], r[6])
    end
    @symbols = read_symbols
  end

  def u32(off) = @bytes[off, 4].unpack1('V')

  # The 32-bit word at virtual address +addr+ in an allocated PROGBITS section, or nil.
  def word_at(addr)
    sec = @sections.find { |s| s.type == 1 && s.flags.anybits?(2) && addr >= s.addr && addr + 4 <= s.addr + s.size }
    sec && u32(sec.offset + addr - sec.addr)
  end

  def section_of(addr)
    @sections.find { |s| s.flags.anybits?(2) && s.size.positive? && addr >= s.addr && addr < s.addr + s.size }
  end

  private

  def cstr(off) = @bytes[off...@bytes.index("\0", off)]

  def read_symbols
    symtab = @sections.find { |s| s.type == 2 }
    raise 'no .symtab (stripped ELF?)' unless symtab

    strtab = @sections[symtab.link].offset
    (symtab.size / 16).times.map do |i|
      name, value, size, info, _other, shndx = @bytes[symtab.offset + (i * 16), 16].unpack('VVVCCv')
      Symbol.new(cstr(strtab + name), value, size, info & 0xf, info >> 4, shndx)
    end
  end
end

abort "usage: #{$PROGRAM_NAME} FIRMWARE.elf [APP_START]" unless ARGV[0]

elf = Elf32.new(ARGV[0])
failures = []
check = lambda do |ok, msg|
  puts "  #{ok ? 'ok' : 'FAIL'}: #{msg}"
  failures << msg unless ok
end
globals = elf.symbols.select { |s| s.bind != 0 && s.shndx != 0 }.to_h { |s| [s.name, s] }
text = elf.sections.find { |s| s.name == '.text' }
abort 'no .text section' unless text
in_text = ->(addr) { addr >= text.addr && addr < text.addr + text.size }

table = globals['exception_table']
check.call(table && table.value == APP_START,
           format('exception_table is at the application start 0x%x (got %s)', APP_START,
                  table ? format('0x%x', table.value) : 'no symbol'))
words = Array.new(table ? [table.size / 4, CORE_VECTORS].max : 0) { |i| elf.word_at(APP_START + (i * 4)) }
check.call(words.any? && words.none?(&:nil?), 'the vector table has file contents in an allocated section')
abort "#{ARGV[0]}: vector table check FAILED" unless failures.empty?

sp = words[0]
check.call(RAM.cover?(sp), format('word 0 (initial SP) 0x%08x is in RAM', sp))
stack_top = globals['__StackTop']
check.call(stack_top.nil? || stack_top.value == sp, 'word 0 is __StackTop') if stack_top

{ 1 => 'Reset_Handler', SYSTICK => 'SysTick_Handler' }.each do |index, name|
  sym = globals[name]
  check.call(sym && in_text.call(sym.value) && words[index] == (sym.value | 1),
             format('word %d is %s|1 in .text (0x%08x)', index, name, words[index]))
end

handlers = words.each_with_index.drop(2).reject { |w, _| w.zero? }
bad = handlers.reject { |w, _| w.odd? && in_text.call(w & ~1) }
check.call(bad.empty?, "all #{handlers.size} non-zero vectors are Thumb addresses in .text" +
                       bad.first(4).map { |w, i| format(' [%d]=0x%08x', i, w) }.join)

# A handler some object overrides (not the weak Dummy_Handler alias) must be what its vector points at.
# UDD_Handler is the USB core's callback, installed at run time through USB_SetHandler, not a vector.
NOT_VECTORS = %w[Dummy_Handler UDD_Handler].freeze
dummy = globals['Dummy_Handler']&.value
wired = words.each_with_index.drop(1).to_h { |w, i| [w & ~1, i] }
overridden = globals.values.select do |s|
  s.name.end_with?('_Handler') && s.type == 2 && s.value != dummy && !NOT_VECTORS.include?(s.name)
end
unwired = overridden.reject { |s| wired.key?(s.value & ~1) }
check.call(unwired.empty?, "#{overridden.size} overriding handlers are wired (#{overridden.map(&:name).sort.join(' ')})" +
                           unwired.map { |s| " unwired: #{s.name}" }.join)

if failures.empty?
  puts "#{ARGV[0]}: vector table check passed"
else
  abort "#{ARGV[0]}: vector table check FAILED (#{failures.size})"
end
