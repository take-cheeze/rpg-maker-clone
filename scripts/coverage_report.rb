#!/usr/bin/env ruby
# encoding: UTF-8
#
# Line-coverage report for the engine's Ruby sources (`mruby-*/mrblib/**.rb`).
#
# Almost all of the runtime is Ruby -- the LCF/RGSS data layers, the RPG2000
# game logic and its scenes, the MV/MZ core -- and it is exercised by the
# `scripts/*_check.rb` harnesses, which load those sources under CRuby (see
# ADR 0049). This runs every one of those harnesses with CRuby's `Coverage`
# stdlib switched on (scripts/coverage_hook.rb, injected through RUBYOPT),
# merges the per-process results and reports which lines the checks reached:
#
#   - a per-gem and per-file summary on stdout,
#   - `coverage/lcov.info`, the standard interchange format (feed it to
#     `genhtml` for an HTML report, or to a coverage service),
#   - `coverage/coverage.json`, the same numbers for scripting,
#   - a Markdown table in the job summary when $GITHUB_STEP_SUMMARY is set.
#
# What it does *not* measure: the mruby-side `rake test` suites and the native
# smoke tests both run inside the built binary, where the CRuby stdlib does not
# exist, so the lines only they reach count as uncovered here. The number is a
# floor on how much of the engine is tested, not a ceiling -- read it as "this
# much is covered by the host-side checks".
#
# Usage: ruby scripts/coverage_report.rb [options]
#
#   --jobs N            run N checks concurrently (default: processor count)
#   --output DIR        write the reports here (default: coverage/)
#   --only PATTERN      only run checks whose name matches PATTERN (substring)
#   --min-line-rate PCT exit non-zero when total line coverage is below PCT
#   --per-file          list every file, not just the least covered ones
#   --list              list the checks and exit
#   --help

require 'coverage'
require 'etc'
require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
HOOK = File.join(__dir__, 'coverage_hook.rb')

# The sources the report is about: the pure-Ruby engine libraries. The
# harnesses under scripts/ are the tests, not the subject, so they are left
# out; `src/**.cxx` is a different language and a different tool (see the ADR).
SOURCE_GLOBS = ['mruby-*/mrblib/**/*.rb'].freeze

# The host-side checks, mirroring the `ruby-checks` job in
# .github/workflows/build.yml plus the one CRuby check CTest owns
# (error_report_check, which covers mruby-rgss/mrblib/error_report.rb). A check
# that needs a downloaded test bed says so with `needs:`; without the data it is
# reported as skipped instead of failing the run, the same way the harnesses
# themselves skip.
CHECKS = [
  { name: 'lcf-testbed',        command: %w[scripts/lcf_testbed_check.rb] },
  { name: 'rpg2k-command-soak', command: %w[scripts/rpg2k_command_soak.rb],
    needs: :rpg2k_game },
  { name: 'rpgxp-testbed',      command: %w[scripts/rpgxp_testbed_check.rb] },
  { name: 'rpgxp-script-host',  command: %w[scripts/rpgxp_script_host_check.rb] },
  { name: 'rpgvx-testbed',      command: %w[scripts/rpgvx_testbed_check.rb] },
  { name: 'mv-testbed',         command: %w[scripts/mv_testbed_check.rb data/mv-sample] },
  { name: 'mz-testbed',         command: %w[scripts/mz_testbed_check.rb data/mz-sample] },
  { name: 'rpg2k-logic',        command: %w[scripts/rpg2k_logic_check.rb] },
  { name: 'rpg2k-scene',        command: %w[scripts/rpg2k_scene_check.rb] },
  { name: 'rpg2k-render',       command: %w[scripts/rpg2k_render_check.rb] },
  { name: 'rpg2k-testbed-logic', command: %w[scripts/rpg2k_testbed_logic_check.rb] },
  { name: 'error-report',       command: %w[scripts/error_report_check.rb] }
].freeze

# `needs:` predicates. A downloaded RPG2000/2003 game is the only prerequisite
# any check has that is not committed to the repository.
REQUIREMENTS = {
  rpg2k_game: {
    description: 'a downloaded RPG2000/2003 test bed under data/ ' \
                 '(scripts/download-nepheshel.bash)',
    met: -> { !Dir.glob(File.join(ROOT, 'data', '**', 'RPG_RT.ldb')).empty? }
  }
}.freeze

options = {
  jobs: Etc.nprocessors,
  output: File.join(ROOT, 'coverage'),
  only: nil,
  min_line_rate: nil,
  per_file: false,
  list: false
}

args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when '--jobs' then options[:jobs] = Integer(args.shift)
  when /\A--jobs=(.+)\z/ then options[:jobs] = Integer(Regexp.last_match(1))
  when '--output' then options[:output] = File.expand_path(args.shift, Dir.pwd)
  when /\A--output=(.+)\z/ then options[:output] = File.expand_path(Regexp.last_match(1), Dir.pwd)
  when '--only' then options[:only] = args.shift
  when /\A--only=(.+)\z/ then options[:only] = Regexp.last_match(1)
  when '--min-line-rate' then options[:min_line_rate] = Float(args.shift)
  when /\A--min-line-rate=(.+)\z/ then options[:min_line_rate] = Float(Regexp.last_match(1))
  when '--per-file' then options[:per_file] = true
  when '--list' then options[:list] = true
  when '-h', '--help'
    puts File.read(__FILE__)[/^# Usage:.*?(?=\n[^#])/m].gsub(/^# ?/, '')
    exit 0
  else
    warn "coverage report: unknown argument #{arg.inspect} (try --help)"
    exit 2
  end
end
options[:jobs] = 1 if options[:jobs] < 1

selected = CHECKS.select { |c| options[:only].nil? || c[:name].include?(options[:only]) }
if selected.empty?
  warn "coverage report: no check matches #{options[:only].inspect}"
  exit 2
end

if options[:list]
  selected.each do |check|
    need = check[:needs] ? "  (needs #{REQUIREMENTS.fetch(check[:needs])[:description]})" : ''
    puts format('%-22s ruby %s%s', check[:name], check[:command].join(' '), need)
  end
  exit 0
end

# --- run the checks, each with the coverage hook injected ------------------

Result = Struct.new(:check, :status, :seconds, :output, :skipped_because)

def run_check(check, coverage_dir)
  requirement = check[:needs] && REQUIREMENTS.fetch(check[:needs])
  if requirement && !requirement[:met].call
    return Result.new(check, nil, 0.0, '', requirement[:description])
  end

  env = {
    'RPG_COVERAGE_DIR' => coverage_dir,
    'RPG_COVERAGE_TAG' => check[:name],
    # Prepended, so a RUBYOPT the caller set (or the dev shell exports) survives.
    'RUBYOPT' => ["-r#{HOOK}", ENV['RUBYOPT']].compact.reject(&:empty?).join(' ')
  }
  command = ['ruby', *check[:command]]

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  # The checks run concurrently, so their output is captured and printed in one
  # piece rather than interleaved on the terminal.
  output = IO.popen(env, command, chdir: ROOT, err: %i[child out], &:read)
  status = $?
  Result.new(check, status.exitstatus, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
             output, nil)
end

coverage_dir = Dir.mktmpdir('rpg-coverage')
results = []
begin
  queue = Queue.new
  selected.each { |check| queue << check }
  mutex = Mutex.new

  workers = Array.new([options[:jobs], selected.size].min) do
    Thread.new do
      while (check = begin
        queue.pop(true)
      rescue ThreadError
        nil
      end)
        result = run_check(check, coverage_dir)
        mutex.synchronize do
          results << result
          if result.skipped_because
            puts format('  skip  %-22s %s', result.check[:name], "needs #{result.skipped_because}")
          else
            puts format('  %-5s %-22s %5.1fs', result.status.zero? ? 'ok' : 'FAIL',
                        result.check[:name], result.seconds)
          end
        end
      end
    end
  end
  puts "Running #{selected.size} host-side check(s) with coverage " \
       "(#{[options[:jobs], selected.size].min} at a time)"
  workers.each(&:join)

  failed = results.reject { |r| r.skipped_because || r.status.zero? }
  failed.each do |result|
    puts
    puts "--- #{result.check[:name]} failed (exit #{result.status}) ---"
    puts result.output
  end

  # --- merge every process's result -----------------------------------------

  merged = {}
  Dir.glob(File.join(coverage_dir, '*.json')).sort.each do |path|
    JSON.parse(File.read(path)).each do |file, counts|
      into = (merged[file] ||= Array.new(counts.size))
      counts.each_with_index do |count, i|
        next if count.nil?

        into[i] = (into[i] || 0) + count
      end
    end
  end
ensure
  FileUtils.remove_entry(coverage_dir)
end

# Files no check ever loaded are absent from the merged result, and dropping
# them would report the covered files' rate as the project's. Ask Coverage for
# their line layout instead, so they land in the report at 0%.
SOURCE_GLOBS.each do |glob|
  Dir.glob(File.join(ROOT, glob)).sort.each do |path|
    relative = path[(ROOT.length + 1)..-1]
    next if merged.key?(relative)

    merged[relative] = Coverage.line_stub(path)
  end
end

# Anything outside the measured sources (a harness under scripts/, say) rode
# along in the raw result; the report is about the engine libraries only.
source_files = SOURCE_GLOBS.flat_map { |g| Dir.glob(File.join(ROOT, g)) }
                           .map { |p| p[(ROOT.length + 1)..-1] }.to_set
merged.select! { |file, _| source_files.include?(file) }

if merged.empty?
  warn 'coverage report: no source file was measured -- nothing to report'
  exit 1
end

# --- shape the numbers ----------------------------------------------------

def stats_for(counts)
  relevant = counts.compact
  { lines: relevant.size, hit: relevant.count { |c| c > 0 } }
end

def rate(stat)
  stat[:lines].zero? ? 100.0 : (stat[:hit] * 100.0 / stat[:lines])
end

files = merged.keys.sort.map do |file|
  stat = stats_for(merged[file])
  { file: file, gem: file[%r{\A[^/]+}], **stat, rate: rate(stat) }
end

groups = files.group_by { |f| f[:gem] }.map do |gem, gem_files|
  stat = { lines: gem_files.sum { |f| f[:lines] }, hit: gem_files.sum { |f| f[:hit] } }
  { gem: gem, **stat, rate: rate(stat) }
end.sort_by { |g| g[:gem] }

total = { lines: files.sum { |f| f[:lines] }, hit: files.sum { |f| f[:hit] } }
total[:rate] = rate(total)

# --- write the reports ----------------------------------------------------

FileUtils.mkdir_p(options[:output])

lcov = +''
files.each do |entry|
  lcov << "TN:\n" << "SF:#{entry[:file]}\n"
  merged[entry[:file]].each_with_index do |count, index|
    lcov << "DA:#{index + 1},#{count}\n" unless count.nil?
  end
  lcov << "LF:#{entry[:lines]}\n" << "LH:#{entry[:hit]}\n" << "end_of_record\n"
end
lcov_path = File.join(options[:output], 'lcov.info')
File.write(lcov_path, lcov)

json_path = File.join(options[:output], 'coverage.json')
File.write(json_path, JSON.pretty_generate(
                        total: total,
                        gems: groups,
                        files: files,
                        checks: results.sort_by { |r| r.check[:name] }.map do |r|
                          { name: r.check[:name],
                            command: r.check[:command].join(' '),
                            status: r.skipped_because ? 'skipped' : (r.status.zero? ? 'ok' : 'failed'),
                            exit_status: r.status,
                            seconds: r.seconds.round(2),
                            skipped_because: r.skipped_because }
                        end
                      ))

# --- report ---------------------------------------------------------------

def bar(percent, width = 24)
  filled = (percent / 100.0 * width).round
  ('#' * filled) + ('.' * (width - filled))
end

# The tail is where the next test belongs, so it is what both the terminal and
# the CI summary lead with. Files with nothing to cover are not interesting
# either way.
lowest = files.reject { |f| f[:lines].zero? }.sort_by { |f| [f[:rate], -f[:lines]] }.first(10)

puts
puts 'Ruby line coverage'
puts
groups.each do |group|
  puts format('  %-14s %s %6.1f%%  %6d / %d', group[:gem], bar(group[:rate]),
              group[:rate], group[:hit], group[:lines])
end
puts format('  %-14s %s %6.1f%%  %6d / %d', 'total', bar(total[:rate]),
            total[:rate], total[:hit], total[:lines])
puts

if options[:per_file]
  puts '  Per file:'
  files.each do |entry|
    puts format('    %-46s %6.1f%%  %6d / %d', entry[:file], entry[:rate],
                entry[:hit], entry[:lines])
  end
else
  puts '  Least covered files (--per-file for all):'
  lowest.each do |entry|
    puts format('    %-46s %6.1f%%  %6d / %d', entry[:file], entry[:rate],
                entry[:hit], entry[:lines])
  end
end
puts
puts "  lcov: #{lcov_path.sub("#{ROOT}/", '')}"
puts "  json: #{json_path.sub("#{ROOT}/", '')}"

skipped = results.select(&:skipped_because)
failed = results.reject { |r| r.skipped_because || r.status.zero? }

# The CI job summary (the run's front page). The headline number and the
# per-gem split are laid out flat; the two lists a reader only sometimes wants
# — where the gaps are, and what was actually run — go in <details> blocks so
# the summary stays one screen. Appended, never truncated: other steps write
# their own sections to the same file.
if (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?
  File.open(summary_path, 'a') do |io|
    io.puts '## Ruby line coverage'
    io.puts
    io.puts format('**%.1f%%** of %d lines in `mruby-*/mrblib` (%d covered), from %d host-side check(s).',
                   total[:rate], total[:lines], total[:hit], results.size - skipped.size)
    io.puts
    io.puts '| Gem | Coverage | Covered | Lines |'
    io.puts '| --- | ---: | ---: | ---: |'
    groups.each do |group|
      io.puts format('| `%s` | %.1f%% | %d | %d |', group[:gem], group[:rate], group[:hit],
                     group[:lines])
    end
    io.puts format('| **total** | **%.1f%%** | %d | %d |', total[:rate], total[:hit], total[:lines])

    unless lowest.empty?
      io.puts
      io.puts '<details><summary>Least covered files</summary>'
      io.puts
      io.puts '| File | Coverage | Covered | Lines |'
      io.puts '| --- | ---: | ---: | ---: |'
      lowest.each do |entry|
        io.puts format('| `%s` | %.1f%% | %d | %d |', entry[:file], entry[:rate], entry[:hit],
                       entry[:lines])
      end
      io.puts
      io.puts '</details>'
    end

    io.puts
    io.puts '<details><summary>Checks measured</summary>'
    io.puts
    io.puts '| Check | Result | Time |'
    io.puts '| --- | --- | ---: |'
    results.sort_by { |r| r.check[:name] }.each do |result|
      state = if result.skipped_because
                "skipped — needs #{result.skipped_because}"
              elsif result.status.zero?
                'ok'
              else
                "**failed** (exit #{result.status})"
              end
      io.puts format('| `%s` | %s | %.1fs |', result.check[:name], state, result.seconds)
    end
    io.puts
    io.puts '</details>'

    io.puts
    io.puts 'Covered by the CRuby harnesses only — `mruby_test` and the native smoke tests ' \
            'run inside mruby, where there is no `Coverage`, so this is a floor. ' \
            'Full report in the `ruby-coverage` artifact (`lcov.info`, `coverage.json`); ' \
            'see `docs/coverage.md`.'
  end
end

unless failed.empty?
  warn "coverage report: #{failed.size} check(s) failed: " \
       "#{failed.map { |r| r.check[:name] }.join(', ')}"
  exit 1
end

if options[:min_line_rate] && total[:rate] < options[:min_line_rate]
  warn format('coverage report: line coverage %.1f%% is below the required %.1f%%',
              total[:rate], options[:min_line_rate])
  exit 1
end

exit 0
