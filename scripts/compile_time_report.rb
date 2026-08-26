#!/usr/bin/env ruby
# encoding: UTF-8
#
# Turns a CI build log captured with -DENABLE_TIME_REPORT=ON (CMakeLists.txt)
# into a "slowest files / slowest compiler phases this run" job-summary
# report.
#
# GCC's own -ftime-report(-details) prints, right after every file it
# actually compiles, a per-phase/per-pass wall-clock breakdown ending in a
# TOTAL line -- a no-op on an sccache cache hit, since sccache then never
# invokes cc1plus at all (see CMakeLists.txt's own comment on
# ENABLE_TIME_REPORT). This scans Ninja's build log for those blocks,
# attributes each one to the "Building CXX/C object ..." status line
# immediately above it, and aggregates:
#
#   - the slowest individual files this run,
#   - time summed by GCC's own top-level "phase" buckets (these are
#     mutually exclusive and sum to the per-file TOTAL, so this splits
#     compile time into e.g. parsing vs. optimization/codegen),
#   - the biggest named passes (these overlap each other and the phases
#     above -- GCC's own accounting nests and cross-cuts them -- so this
#     list is a set of individually-true "this pass cost this much"
#     hints, not a second partition of the same total).
#
# Usage: ruby scripts/compile_time_report.rb <build.log> [--top N]
#
#   --top N   how many slowest files / passes to list (default 20)
#   --help
#
# Writes a Markdown report to $GITHUB_STEP_SUMMARY when set (appended, like
# every other *_report.rb in this directory), and a plain-text summary to
# stdout either way.

top_n = 20
path = nil
args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when '--top' then top_n = Integer(args.shift)
  when /\A--top=(.+)\z/ then top_n = Integer(Regexp.last_match(1))
  when '-h', '--help'
    puts File.read(__FILE__)[/^# Usage:.*?(?=\n[^#])/m].gsub(/^# ?/, '')
    exit 0
  else
    if path
      warn "compile_time_report: unexpected argument #{arg.inspect} (try --help)"
      exit 2
    end
    path = arg
  end
end

if path.nil?
  warn 'compile_time_report: missing <build.log> argument (try --help)'
  exit 2
end

def write_no_data_summary(reason)
  return unless (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?

  File.open(summary_path, 'a') do |io|
    io.puts '## Compile-time bottleneck hints'
    io.puts
    io.puts reason
  end
end

unless File.exist?(path)
  puts "compile_time_report: #{path} not found -- nothing to report"
  write_no_data_summary("Build log `#{path}` not found -- nothing to report.")
  exit 0
end

# Ninja's default status line, e.g. "[123/456] Building CXX object foo.cxx.o".
STATUS_LINE = /\A\[\d+\/\d+\]\s+(.+?)\s*\z/
# A phase/pass row, e.g.
#   " phase parsing            :   0.24 ( 96%)   0.11 ( 92%)   0.34 ( 87%)  19M ( 88%)"
#   " `- template instantiation:   0.00 (  0%)   0.00 (  0%)   0.01 (  3%)  452k (  2%)"
# The optional leading "`- " or "|" marks a nested drill-down of an already-
# counted parent row -- excluded from the sums below to avoid double-counting.
MEASURED_ROW =
  /\A\s*(`- |\|)?(.+?)\s*:\s*[\d.]+\s*\(\s*\d+%\)\s+[\d.]+\s*\(\s*\d+%\)\s+([\d.]+)\s*\(\s*\d+%\)\s+\S+\s*\(\s*\d+%\)\s*\z/
# The block-ending totals row, e.g. " TOTAL  :   0.25   0.12   0.39   21M" --
# same 4 columns as above but with no percentages.
TOTAL_ROW = /\A\s*TOTAL\s*:\s*[\d.]+\s+[\d.]+\s+([\d.]+)\s+\S+\s*\z/

FileReport = Struct.new(:label, :wall, :phases, :passes)

reports = []
current_label = nil
in_block = false
phases = nil
passes = nil

File.foreach(path, encoding: 'UTF-8', invalid: :replace, undef: :replace) do |line|
  if (m = STATUS_LINE.match(line))
    # Strip Ninja's own "Building CXX/C/ASM object " prefix -- it's identical
    # on every row, so the object path alone reads better in a ranked list.
    current_label = m[1].sub(/\ABuilding \S+ object /, '')
    next
  end

  if line.start_with?('Time variable')
    in_block = true
    phases = Hash.new(0.0)
    passes = Hash.new(0.0)
    next
  end

  next unless in_block

  if (m = TOTAL_ROW.match(line))
    reports << FileReport.new(current_label || '(unknown file)', m[1].to_f, phases, passes)
    in_block = false
    next
  end

  next unless (m = MEASURED_ROW.match(line))

  next if m[1] # nested drill-down row, already counted in its parent

  name = m[2]
  wall = m[3].to_f
  if name.start_with?('phase ')
    phases[name] += wall
  else
    passes[name] += wall
  end
end

if reports.empty?
  puts 'compile_time_report: no -ftime-report block found in the log ' \
       '(a fully cache-hit run recompiles nothing) -- nothing to report'
  write_no_data_summary('No file was actually recompiled this run (full sccache cache hit) -- ' \
                        'nothing to report.')
  exit 0
end

total_wall = reports.sum(&:wall)
slowest = reports.sort_by { |r| -r.wall }.first(top_n)

phase_totals = Hash.new(0.0)
pass_totals = Hash.new(0.0)
reports.each do |r|
  r.phases.each { |k, v| phase_totals[k] += v }
  r.passes.each { |k, v| pass_totals[k] += v }
end
top_phases = phase_totals.sort_by { |_, v| -v }.first(10)
top_passes = pass_totals.sort_by { |_, v| -v }.first(top_n)

pct = ->(wall) { total_wall.zero? ? 0.0 : (wall * 100.0 / total_wall) }

puts
puts 'Compile-time bottleneck hints (-ftime-report)'
puts
puts format('  %d file(s) recompiled this run, %.1fs of measured compiler wall time total',
            reports.size, total_wall)
puts
puts '  Slowest files:'
slowest.each { |r| puts format('    %7.2fs  %s', r.wall, r.label) }
puts
puts '  Time by phase (mutually exclusive, sums to the total above):'
top_phases.each { |name, wall| puts format('    %7.2fs (%5.1f%%)  %s', wall, pct.call(wall), name) }
puts
puts '  Notable passes (informational -- overlap each other and the phases above):'
top_passes.each { |name, wall| puts format('    %7.2fs  %s', wall, name) }

if (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?
  File.open(summary_path, 'a') do |io|
    io.puts '## Compile-time bottleneck hints'
    io.puts
    io.puts format('**%d** file(s) recompiled this run (sccache cache misses only), ' \
                   '**%.1fs** of measured compiler wall time total (`-ftime-report`). ' \
                   'A fully warm cache reports nothing here -- this only grows informative ' \
                   'exactly when a run recompiles a lot.',
                   reports.size, total_wall)
    io.puts
    io.puts '<details><summary>Slowest files this run</summary>'
    io.puts
    io.puts '| File | Wall (s) |'
    io.puts '| --- | ---: |'
    slowest.each { |r| io.puts format('| `%s` | %.2f |', r.label, r.wall) }
    io.puts
    io.puts '</details>'
    io.puts
    io.puts '<details><summary>Time by phase (mutually exclusive, sums to the total above)</summary>'
    io.puts
    io.puts '| Phase | Wall (s) | % of total |'
    io.puts '| --- | ---: | ---: |'
    top_phases.each { |name, wall| io.puts format('| %s | %.2f | %.1f%% |', name, wall, pct.call(wall)) }
    io.puts
    io.puts '</details>'
    io.puts
    io.puts '<details><summary>Notable passes (overlap each other and the phases above)</summary>'
    io.puts
    io.puts '| Pass | Wall (s) |'
    io.puts '| --- | ---: |'
    top_passes.each { |name, wall| io.puts format('| %s | %.2f |', name, wall) }
    io.puts
    io.puts '</details>'
  end
end
