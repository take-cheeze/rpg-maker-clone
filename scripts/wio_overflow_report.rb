#!/usr/bin/env ruby
# encoding: UTF-8
#
# Turns the `wio_rgss_boot` linker maps a baseline/RPGMAKER_BC2CPP=1 pair of
# builds produces (scripts/wio_bc2cpp_measure.bash) into the flash/RAM overflow
# statistics ADRs 0104-0144 have so far only recorded by hand -- the A/B table
# (each build's section sizes, flash needed, real overflow and % of the 507904
# -byte budget, plus the delta) and a best-effort per-object/archive breakdown
# of the bc2cpp image. CI's `wio-bc2cpp` job runs it against the captured maps;
# see docs/adr/0152.
#
# A `wio_rgss_boot` link no longer produces a firmware.elf (it overflows the
# real FLASH region), so PlatformIO's own "Checking size ..." lines -- what
# scripts/wio_size_report.rb reformats -- never appear for it. What the failed
# link does still write is firmware.map, which is exactly the data this reads:
# GNU ld completes the whole layout before refusing to emit the ELF
# (docs/adr/0142/0143). When a map is paired with the build log that produced
# it (a `build.log` beside it), the log's own `region `FLASH' overflowed by N
# bytes` line is reported as a cross-check against the map-derived number.
#
# Usage:
#   ruby scripts/wio_overflow_report.rb [LABEL:]MAP [[LABEL:]MAP ...]
#                                       [--flash-budget N] [--ram-budget N]
#                                       [--top N]
#
# Example (the two builds scripts/wio_bc2cpp_measure.bash writes):
#   ruby scripts/wio_overflow_report.rb \
#     baseline:/tmp/wio-bc2cpp/baseline/firmware.map \
#     bc2cpp:/tmp/wio-bc2cpp/bc2cpp/firmware.map
#
# LABEL defaults to the map's parent directory name; the sibling build.log (if
# present) supplies the ld cross-check. Writes a Markdown report to
# $GITHUB_STEP_SUMMARY when set (appended, like every other *_report.rb in this
# directory), and a plain-text summary to stdout either way.

if ARGV.empty? || %w[-h --help].include?(ARGV.first)
  puts File.read(__FILE__)[/^# Usage:.*?(?=\n[^#])/m].gsub(/^# ?/, '')
  exit(ARGV.empty? ? 2 : 0)
end

FLASH_BUDGET = 507_904
RAM_BUDGET = 196_608

entries = [] # [label, map_path]
flash_budget = FLASH_BUDGET
ram_budget = RAM_BUDGET
top_n = 15

args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when '--flash-budget'
    flash_budget = Integer(args.shift, 10)
  when /\A--flash-budget=(.*)\z/
    flash_budget = Integer(Regexp.last_match(1), 10)
  when '--ram-budget'
    ram_budget = Integer(args.shift, 10)
  when /\A--ram-budget=(.*)\z/
    ram_budget = Integer(Regexp.last_match(1), 10)
  when '--top'
    top_n = Integer(args.shift, 10)
  when /\A--top=(.*)\z/
    top_n = Integer(Regexp.last_match(1), 10)
  when /\A-/
    warn "wio_overflow_report: unknown option #{arg}"
    exit 2
  else
    label, path = arg.split(':', 2)
    if path.nil?
      path = label
      label = File.basename(File.dirname(File.expand_path(path)))
    end
    entries << [label, path]
  end
end

if entries.empty?
  warn 'wio_overflow_report: no firmware.map given'
  exit 2
end

def write_no_data_summary(reason)
  return unless (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?

  File.open(summary_path, 'a') do |io|
    io.puts '## Wio Terminal flash overflow (bc2cpp)'
    io.puts
    io.puts reason
  end
end

def commas(n)
  n.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
end

# The output-section totals, from the "Linker script and memory map" listing.
# Each output section's header line is at column 0 and reads
#   .text           0x0000000000080000    0x11d2a0
# (input sections are indented, and a plain symbol assignment has one address
# and no size, so anchoring at column 0 with two hex fields is unambiguous).
# Only the first match per section is taken; there is one of each here.
SECTION_LINE = /\A(\.text|\.ARM\.extab|\.ARM\.exidx|\.data|\.bss)\s+0x[0-9a-fA-F]+\s+0x([0-9a-fA-F]+)/

# Input sections, for the per-object/archive tally. Both the one-line form
#   .text.foo  0x0000000000080010  0x40 /path/foo.o
# and the wrapped form (name alone, address/size/file on the next line) occur.
INPUT_LINE = /\A\s+(\S+)\s+0x[0-9a-fA-F]+\s+0x([0-9a-fA-F]+)\s+(\S.*?)\s*\z/
NAME_ONLY = /\A\s+(\.\S+)\s*\z/
SIZE_ONLY = /\A\s+0x[0-9a-fA-F]+\s+0x([0-9a-fA-F]+)\s+(\S.*?)\s*\z/
# Flash-resident input sections (docs/adr/0141's own set: .data's initialised
# bytes are part of the load image too).
FLASH_PREFIXES = ['.text', '.rodata', '.data', '.ARM.extab', '.ARM.exidx'].freeze

# ld's own overflow message, verbatim from docs/adr/0104 onward -- backtick
# before the region name, ASCII apostrophe after:  region `FLASH' overflowed by N bytes
LD_OVERFLOW = /region `(FLASH|RAM)' overflowed by (\d+) bytes/
# PlatformIO's post-link size line, for the case where a build ever *fits*
# instead: "Flash: [===] 33.6% (used 170608 bytes from 507904 bytes)".
PIO_USAGE = /\A(RAM|Flash):\s+\[.*?\]\s+[\d.]+% \(used (\d+) bytes from (\d+) bytes\)\s*\z/

def object_label(file)
  if file =~ %r{([^/\\]+\.a)\(([^)]+)\)}
    "#{Regexp.last_match(1)}(#{Regexp.last_match(2)})"
  else
    File.basename(file)
  end
end

MAP_HEADING = /\ALinker script and memory map\b/

def parse_map(path)
  sections = {}
  objects = Hash.new(0)
  pending = nil
  in_map = false
  File.foreach(path, encoding: 'UTF-8', invalid: :replace, undef: :replace) do |line|
    line = line.chomp
    # Only the placed sections count. Earlier listings ("Archive member
    # included...", "Discarded input sections") carry sizes too, but of
    # sections that are not in the image.
    unless in_map
      in_map = true if MAP_HEADING.match?(line)
      next
    end
    if (m = INPUT_LINE.match(line))
      section, size, file = m[1], m[2].to_i(16), m[3]
      pending = nil
    elsif (m = NAME_ONLY.match(line))
      pending = m[1]
      next
    elsif pending && (m = SIZE_ONLY.match(line))
      section, size, file = pending, m[1].to_i(16), m[2]
      pending = nil
    else
      pending = nil
      if (m = SECTION_LINE.match(line)) && !sections.key?(m[1])
        sections[m[1]] = m[2].to_i(16)
      end
      next
    end
    next unless FLASH_PREFIXES.any? { |p| section.start_with?(p) }

    objects[object_label(file)] += size
  end
  [sections, objects]
end

def parse_log(path)
  out = { ld_flash: nil, ld_ram: nil, pio_flash: nil, pio_ram: nil }
  return out unless File.exist?(path)

  File.foreach(path, encoding: 'UTF-8', invalid: :replace, undef: :replace) do |line|
    if (m = LD_OVERFLOW.match(line))
      m[1] == 'FLASH' ? out[:ld_flash] = m[2].to_i : out[:ld_ram] = m[2].to_i
    elsif (m = PIO_USAGE.match(line))
      m[1] == 'Flash' ? out[:pio_flash] = m[2].to_i : out[:pio_ram] = m[2].to_i
    end
  end
  out
end

Usage = Struct.new(:label, :map, :sections, :objects, :log) do
  def section(name) = sections[name]
  def text = sections['.text']
  def extab = sections['.ARM.extab']
  def exidx = sections['.ARM.exidx']
  def data = sections['.data']
  def bss = sections['.bss']
  def complete? = [text, extab, exidx, data, bss].all?
  def flash_needed = complete? ? text + extab + exidx : nil
  def ram_used = complete? ? data + bss : nil
end

rows = []
build_failures = {}
entries.each do |label, path|
  unless File.exist?(path)
    # A variant whose build failed leaves no map; scripts/wio_bc2cpp_measure.bash
    # drops the compiler error beside where the map would be, so the report can
    # say *why* instead of silently omitting the row.
    note = File.join(File.dirname(path), 'rake-failed.txt')
    build_failures[label] = File.read(note, encoding: 'UTF-8', invalid: :replace, undef: :replace) if File.exist?(note)
    puts "wio_overflow_report: #{path} not found -- skipping #{label}"
    next
  end
  sections, objects = parse_map(path)
  rows << Usage.new(label, path, sections, objects, parse_log(File.join(File.dirname(path), 'build.log')))
end

def failure_section(io, build_failures)
  return if build_failures.empty?

  io.puts
  io.puts '### Build failures'
  build_failures.each do |label, note|
    io.puts
    io.puts "`#{label}` did not build, so it has no map to measure (last lines of the compiler/linker output):"
    io.puts
    io.puts '```'
    note.strip.lines.last(20).each { |l| io.puts l.chomp }
    io.puts '```'
  end
end

if rows.empty? || rows.none?(&:complete?)
  detail = rows.map { |r| "`#{r.map}`" }.join(', ')
  puts "wio_overflow_report: no complete section totals found (#{detail}) -- nothing to report"
  if build_failures.empty?
    write_no_data_summary('No linker map with `.text`/`.ARM.extab`/`.ARM.exidx`/`.data`/`.bss` totals found -- nothing to report.')
  elsif (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?
    File.open(summary_path, 'a') do |io|
      io.puts '## Wio Terminal flash overflow (bc2cpp)'
      io.puts
      io.puts 'No linker map to measure.'
      failure_section(io, build_failures)
    end
  end
  exit 0
end

def fmt_int(n) = n.nil? ? '—' : commas(n)

def delta(a, b)
  return nil if a.nil? || b.nil?

  b - a
end

puts 'Wio Terminal flash overflow:'
rows.each do |r|
  next unless r.complete?

  flash = r.flash_needed
  ram = r.ram_used
  puts format('  %-10s flash %s / %s bytes (%.1f%% of budget), RAM %s / %s bytes (%.1f%%)%s',
              r.label, commas(flash), commas(FLASH_BUDGET), flash * 100.0 / FLASH_BUDGET,
              commas(ram), commas(RAM_BUDGET), ram * 100.0 / RAM_BUDGET,
              r.log[:ld_flash] ? " [ld: overflowed by #{commas(r.log[:ld_flash])}]" : '')
end

if (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?
  File.open(summary_path, 'a') do |io|
    io.puts '## Wio Terminal flash overflow (bc2cpp)'
    io.puts
    io.puts "Budgets: FLASH #{commas(FLASH_BUDGET)} bytes, SRAM #{commas(RAM_BUDGET)} bytes. " \
            'The `wio_rgss_boot` link overflows FLASH by design at every coverage scope measured ' \
            'so far (docs/adr/0104 onward); this is an advisory report, not a gate. ' \
            '`ld` still writes a complete `firmware.map` before refusing to emit the ELF, which is what the section totals come from.'
    io.puts

    io.puts '| build | `.text` | `.ARM.extab` | `.ARM.exidx` | flash needed | flash overflow | % of budget | `ld` FLASH |'
    io.puts '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
    rows.each do |r|
      next unless r.complete?

      io.puts format('| `%s` | %s | %s | %s | %s | %s | %.1f%% | %s |',
                     r.label, fmt_int(r.text), fmt_int(r.extab), fmt_int(r.exidx),
                     fmt_int(r.flash_needed), fmt_int(r.flash_needed - FLASH_BUDGET),
                     r.flash_needed * 100.0 / FLASH_BUDGET,
                     r.log[:ld_flash] ? fmt_int(r.log[:ld_flash]) : '—')
    end
    if rows.length >= 2 && rows.all?(&:complete?)
      base, last = rows.first, rows.last
      io.puts format('| Δ `%s` − `%s` | %s | %s | %s | %s | %s | | |',
                     last.label, base.label,
                     fmt_int(delta(base.text, last.text)),
                     fmt_int(delta(base.extab, last.extab)),
                     fmt_int(delta(base.exidx, last.exidx)),
                     fmt_int(delta(base.flash_needed, last.flash_needed)),
                     fmt_int(delta(base.flash_needed, last.flash_needed)))
    end
    io.puts
    io.puts '| build | `.data` | `.bss` | RAM used | % of budget |'
    io.puts '| --- | ---: | ---: | ---: | ---: |'
    rows.each do |r|
      next unless r.complete?

      io.puts format('| `%s` | %s | %s | %s | %.1f%% |',
                     r.label, fmt_int(r.data), fmt_int(r.bss), fmt_int(r.ram_used),
                     r.ram_used * 100.0 / RAM_BUDGET)
    end

    detail_row = rows.find { |r| r.label == 'bc2cpp' } || rows.last
    unless detail_row.objects.empty?
      io.puts
      io.puts '<details><summary>Top flash contributors by object/archive ' \
              "(#{detail_row.label}, gross per-input-section sums)</summary>"
      io.puts
      io.puts '| object / archive | bytes |'
      io.puts '| --- | ---: |'
      detail_row.objects.sort_by { |_, v| -v }.first(top_n).each do |name, bytes|
        io.puts format('| `%s` | %s |', name, commas(bytes))
      end
      io.puts
      io.puts 'Gross per-input-section sums: they overshoot the linked totals above by a few percent ' \
              '(docs/adr/0141/0143), and the first entry of each mergeable-strings group is inflated ' \
              'by the map’s own `(size before relaxing)` artefact, uncorrected here.'
      io.puts
      io.puts '</details>'
    end

    failure_section(io, build_failures)
  end
end
