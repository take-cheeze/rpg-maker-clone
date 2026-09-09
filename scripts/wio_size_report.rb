#!/usr/bin/env ruby
# encoding: UTF-8
#
# Turns a captured `pio run` build log for the Wio Terminal firmwares into a
# flash/RAM job-summary report -- this project's own ADR 91+ series (see
# docs/adr/0091 onward) tracks the Wio Terminal's SAMD51 flash (512 KB) and
# SRAM (192 KB) budget closely enough that CI should surface it on every run,
# not just the real-relink numbers each individual ADR reports by hand.
#
# PlatformIO's own `pio run` prints, right after linking each environment's
# firmware.elf, a "Checking size .../firmware.elf" line followed by one
# RAM:/Flash: line each (percent bar, used/total bytes) -- this scans a log
# for those triples and turns them into a table, one row per environment
# actually found. No parsing of .elf/.map files itself: this only reformats
# what `pio run` already computed and printed, the same way
# compile_time_report.rb only reformats GCC's own -ftime-report output
# rather than re-deriving it.
#
# Usage: ruby scripts/wio_size_report.rb <build.log> [<build.log> ...]
#
# Multiple logs are accepted (and merged into one table) so a job that runs
# `pio run -e wio`, `pio run -e wio_walk`, `pio run -e wio_sd_upload` as
# separate commands -- as CI's own wio job does -- can tee each to its own
# file, or all to one, either way.
#
# Writes a Markdown report to $GITHUB_STEP_SUMMARY when set (appended, like
# every other *_report.rb in this directory), and a plain-text summary to
# stdout either way.

if ARGV.empty? || %w[-h --help].include?(ARGV.first)
  puts File.read(__FILE__)[/^# Usage:.*?(?=\n[^#])/m].gsub(/^# ?/, '')
  exit(ARGV.empty? ? 2 : 0)
end

paths = ARGV.dup

def write_no_data_summary(reason)
  return unless (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?

  File.open(summary_path, 'a') do |io|
    io.puts '## Wio Terminal firmware size'
    io.puts
    io.puts reason
  end
end

missing = paths.reject { |p| File.exist?(p) }
unless missing.empty?
  puts "wio_size_report: #{missing.join(', ')} not found -- nothing to report"
  write_no_data_summary("Build log(s) #{missing.map { |p| "`#{p}`" }.join(', ')} not found -- nothing to report.")
  exit 0
end

# "Checking size .pio/build/wio_walk/firmware.elf"
ENV_LINE = %r{\ACheck(?:ing)? size \S*/build/([^/]+)/firmware\.elf\s*\z}
# "RAM:   [=         ]   9.0% (used 17704 bytes from 196608 bytes)"
# "Flash: [===       ]  33.6% (used 170608 bytes from 507904 bytes)"
USAGE_LINE = /\A(RAM|Flash):\s+\[.*?\]\s+([\d.]+)% \(used (\d+) bytes from (\d+) bytes\)\s*\z/

Usage = Struct.new(:env, :ram_used, :ram_total, :ram_pct, :flash_used, :flash_total, :flash_pct)

by_env = {}
paths.each do |path|
  current = nil
  File.foreach(path) do |line|
    line = line.chomp
    if (m = ENV_LINE.match(line))
      current = (by_env[m[1]] ||= Usage.new(m[1]))
      next
    end
    next unless current && (m = USAGE_LINE.match(line))

    pct, used, total = m[2].to_f, m[3].to_i, m[4].to_i
    if m[1] == 'RAM'
      current.ram_used, current.ram_total, current.ram_pct = used, total, pct
    else
      current.flash_used, current.flash_total, current.flash_pct = used, total, pct
    end
  end
end

if by_env.empty?
  puts 'wio_size_report: no "Checking size .../firmware.elf" + RAM:/Flash: blocks found -- nothing to report'
  write_no_data_summary('No `pio run` size output found in the build log(s) -- nothing to report.')
  exit 0
end

rows = by_env.values.sort_by(&:env)

puts 'Wio Terminal firmware size:'
rows.each do |r|
  puts format('  %-14s RAM: %6d / %6d bytes (%5.1f%%)   Flash: %7d / %7d bytes (%5.1f%%)',
              r.env, r.ram_used, r.ram_total, r.ram_pct, r.flash_used, r.flash_total, r.flash_pct)
end

if (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?
  File.open(summary_path, 'a') do |io|
    io.puts '## Wio Terminal firmware size'
    io.puts
    io.puts '| Environment | RAM used | RAM % | Flash used | Flash % |'
    io.puts '| --- | ---: | ---: | ---: | ---: |'
    rows.each do |r|
      io.puts format('| `%s` | %d / %d B | %.1f%% | %d / %d B | %.1f%% |',
                      r.env, r.ram_used, r.ram_total, r.ram_pct,
                      r.flash_used, r.flash_total, r.flash_pct)
    end
  end
end
