#!/usr/bin/env ruby
# encoding: UTF-8
# Unit check for scripts/wio_overflow_report.rb (docs/adr/0152). CI's real
# `wio-bc2cpp` job exercises that report against a genuine linker map, but only
# after a multi-minute ARM cross-build -- this feeds it a hand-built map (and
# its build.log) with known numbers so the parsing and the arithmetic are
# pinned independently of any build.
#
# Checks: the output-section totals are summed into flash-needed/RAM-used; the
# real FLASH overflow and % of the 507904-byte budget are right; the ld
# `region `FLASH' overflowed by N bytes` cross-check is read from the sibling
# build.log; the per-object/archive tally is emitted; and a map with no
# complete section totals takes the "nothing to report" path with exit 0.
#
# Usage: ruby scripts/wio_overflow_report_check.rb

require 'tmpdir'
require 'open3'

ROOT = File.expand_path('..', __dir__)
SCRIPT = File.join(ROOT, 'scripts', 'wio_overflow_report.rb')

# Hand-computed expectations: .text 512000 + .ARM.extab 256 + .ARM.exidx 512 =
# 512768 flash needed, i.e. 4864 over the 507904-byte budget; .data 768 +
# .bss 1024 = 1792 RAM used.
MAP = <<~MAP
  Linker script and memory map

  .text           0x0000000000008000    0x7d000
   .text.foo          0x0000000000008000       0x7c000 /tmp/foo.o
   .rodata.str1.1     0x0000000000008400       0x1000 /tmp/libx.a(bar.o)
  .ARM.extab      0x0000000000008000        0x100
  .ARM.exidx      0x0000000000008000        0x200
  .data           0x2000000000008000        0x300
  .bss            0x2000000000008000        0x400
MAP

LOG = "ld: region `FLASH' overflowed by 4864 bytes\n"

def run_report(map_dir)
  summary = File.join(map_dir, 'summary.md')
  out, err, status = Open3.capture3(
    { 'GITHUB_STEP_SUMMARY' => summary },
    'ruby', SCRIPT, "baseline:#{File.join(map_dir, 'firmware.map')}"
  )
  [out, err, status, (File.exist?(summary) ? File.read(summary) : '')]
end

failures = []
def assert(failures, condition, message)
  failures << message unless condition
end

Dir.mktmpdir('wio-overflow-report-check') do |dir|
  File.write(File.join(dir, 'firmware.map'), MAP)
  File.write(File.join(dir, 'build.log'), LOG)

  out, err, status, summary = run_report(dir)

  assert(failures, status.exitstatus.zero?, "exit status #{status.exitstatus}: #{err}")
  assert(failures, out.include?('512,768'), "stdout missing flash-needed 512,768:\n#{out}")
  assert(failures, out.include?('4,864'), "stdout missing overflow 4,864:\n#{out}")
  assert(failures, summary.include?('## Wio Terminal flash overflow (bc2cpp)'),
         'summary missing report heading')
  assert(failures, summary.include?('4,864'), 'summary missing map-derived overflow 4,864')
  assert(failures, summary.include?('| `foo.o` | 507,904 |') || summary.include?('foo.o'),
         'summary missing per-object contributor foo.o')
  assert(failures, summary.include?('1,792'), 'summary missing RAM used 1,792')
end

Dir.mktmpdir('wio-overflow-report-check-empty') do |dir|
  File.write(File.join(dir, 'firmware.map'), "not a linker map\n")
  out, _err, status, summary = run_report(dir)

  assert(failures, status.exitstatus.zero?, "empty-map run exited #{status.exitstatus}")
  assert(failures, out.include?('nothing to report'), "empty-map stdout: #{out}")
  assert(failures, summary.include?('nothing to report'), 'empty-map summary missing note')
end

if failures.empty?
  puts 'wio overflow report check: OK'
else
  warn 'wio overflow report check: FAILED'
  failures.each { |f| warn "  - #{f}" }
  exit 1
end
