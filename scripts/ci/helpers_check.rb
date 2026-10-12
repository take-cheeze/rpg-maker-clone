#!/usr/bin/env ruby
# frozen_string_literal: true

# The CI speed-up helpers (docs/ci.md): the compiler launcher (bc2cpp_cxx.rb), the mutant pool
# (bc2cpp_mutant_pool.rb) and the timing wrapper (ci_timed_checks.rb). They gate the bc2cpp shards,
# so a bug in one must fail here rather than as a hung or silently shorter shard.
#
# Usage: ruby scripts/ci/helpers_check.rb

require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../bc2cpp/cxx'
require_relative '../bc2cpp/mutant_pool'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- Bc2cppCxx -------------------------------------------------------------------------------------
puts '-- compiler launcher'
with_launcher = lambda do |launcher, cxx: nil, &block|
  saved = [Bc2cppCxx.instance_variable_get(:@launcher), ENV.fetch('CXX', nil)]
  Bc2cppCxx.instance_variable_set(:@launcher, launcher)
  ENV['CXX'] = cxx
  block.call
ensure
  Bc2cppCxx.instance_variable_set(:@launcher, saved[0])
  ENV['CXX'] = saved[1]
end
args = ['-std=c++17', '-w', '-I/tmp/fx', '-I/opt/mruby/include', '-DX=1', '/tmp/fx/main.cpp', '/opt/mruby/lib/libmruby.a', '-lm',
        '-o', '/tmp/fx/fixture']

with_launcher.call(nil) do
  check.call('without a launcher the arguments pass through to g++ untouched', Bc2cppCxx.plan(args) == [[['g++', *args], {}]])
  check.call('without a launcher CXX is honoured', with_launcher.call(nil, cxx: 'c++') { Bc2cppCxx.plan(['-c', 'a.cpp']) } == [[%w[c++ -c a.cpp], {}]])
  check.call('without a launcher rake gets no CC/CXX', Bc2cppCxx.rake_env == {})
end

with_launcher.call('/usr/bin/sccache') do
  compile, link = Bc2cppCxx.plan(args)
  check.call('a one-source build becomes a cached compile and a link', Bc2cppCxx.plan(args).size == 2)
  check.call('the compile goes through the launcher as -c, from the source directory spelled .',
             compile == [['/usr/bin/sccache', 'g++', '-std=c++17', '-w', '-I.', '-I/opt/mruby/include', '-DX=1', '-c', 'main.cpp', '-o',
                          '/tmp/fx/fixture.o'], { chdir: '/tmp/fx' }])
  check.call('the link takes the object, then the libraries, without -I/-D',
             link == [['g++', '-std=c++17', '-w', '/tmp/fx/fixture.o', '/opt/mruby/lib/libmruby.a', '-lm', '-o', '/tmp/fx/fixture'], {}])
  check.call('-fsyntax-only is not split', Bc2cppCxx.plan(['-fsyntax-only', '/tmp/a.cpp']) == [[%w[g++ -fsyntax-only /tmp/a.cpp], {}]])
  check.call('two sources are not split', Bc2cppCxx.plan(%w[/a.cpp /b.cpp -o /x]).size == 1)
  relative = Bc2cppCxx.plan(['-Irel', '/tmp/fx/main.cpp', '-o', '/tmp/fx/bin'])
  check.call('a relative include path keeps the working directory',
             relative.first.last == {} && relative.first.first.include?('/tmp/fx/main.cpp'))
  check.call('a launcher already in CXX is not doubled',
             with_launcher.call('/usr/bin/sccache', cxx: 'sccache g++') { Bc2cppCxx.plan(['-c', '/a.cpp', '-o', '/a.o']) }.first.first.first(2) == %w[sccache g++])
  env = Bc2cppCxx.rake_env
  check.call('rake builds get the launcher for CC and CXX', env['CC'].start_with?('/usr/bin/sccache ') && env['CXX'].start_with?('/usr/bin/sccache '))
end

Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'main.cpp'), "#include \"h.hpp\"\nint main() { return H; }\n")
  File.write(File.join(dir, 'h.hpp'), "#define H 7\n")
  out = File.join(dir, 'bin')
  fake = File.join(dir, 'fake-launcher')
  File.write(fake, "#!/bin/sh\nexec \"$@\"\n")
  File.chmod(0o755, fake)
  [nil, fake].each do |launcher|
    with_launcher.call(launcher) do
      built = Bc2cppCxx.system('-w', "-I#{dir}", File.join(dir, 'main.cpp'), '-o', out)
      check.call("a build runs and links (launcher: #{launcher ? 'yes' : 'no'})", built && system(out) == false && $?.exitstatus == 7)
      _stdout, stderr, status = Bc2cppCxx.capture3('-w', File.join(dir, 'missing.cpp'), '-o', out)
      check.call("a failing build reports failure through capture3 (launcher: #{launcher ? 'yes' : 'no'})",
                 !status.success? && !stderr.empty?)
    end
  end
end

# -- Bc2cppMutantPool -----------------------------------------------------------------------------
puts '-- mutant pool'
order = []
started = Queue.new
work = lambda do |(n, delay)|
  started << n
  sleep delay
  n * 10
end
Bc2cppMutantPool.each_ordered([[1, 0.4], [2, 0.0], [3, 0.0]], work: work, jobs: 3) { |(n, _), result| order << [n, result] }
check.call('results arrive in input order although the first item finishes last', order == [[1, 10], [2, 20], [3, 30]])
check.call('jobs: 1 runs one at a time', begin
  running = 0
  peak = 0
  lock = Mutex.new
  Bc2cppMutantPool.each_ordered([1, 2, 3], jobs: 1,
                                work: lambda { |_|
                                  lock.synchronize { running += 1; peak = [peak, running].max }
                                  sleep 0.05
                                  lock.synchronize { running -= 1 }
                                }) { |_item, _result| nil }
  peak == 1
end)
raised = begin
  Bc2cppMutantPool.each_ordered([1, 2], work: ->(n) { raise ArgumentError, 'boom' if n == 2 }) { |_item, _result| nil }
  nil
rescue ArgumentError => e
  e.message
end
check.call('an exception in the work is re-raised, not swallowed', raised == 'boom')
ok = Bc2cppMutantPool.run({}, [RbConfig.ruby, '-e', 'puts "  ok   fine"'], stop_on: /^\s+FAIL /)
check.call('a clean run is a success with its output', ok.success && !ok.stopped && ok.out == "  ok   fine\n")
bad = Bc2cppMutantPool.run({}, [RbConfig.ruby, '-e', 'puts "  FAIL x"; exit 1'])
check.call('a failing run is not a success', !bad.success && !bad.stopped)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
early = Bc2cppMutantPool.run({}, [RbConfig.ruby, '-e', '$stdout.sync = true; puts "  FAIL caught"; sleep 60'], stop_on: /^\s+FAIL /)
check.call('the first matching line stops the child at once', early.stopped && !early.success && early.out.include?('FAIL caught') &&
                                                           Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 < 30)
check.call('BC2CPP_JOBS bounds the pool', begin
  saved = ENV.fetch('BC2CPP_JOBS', nil)
  ENV['BC2CPP_JOBS'] = '2'
  Bc2cppMutantPool.jobs == 2
ensure
  ENV['BC2CPP_JOBS'] = saved
end)

# -- ci_timed_checks.rb ----------------------------------------------------------------------------
puts '-- timing wrapper'
Dir.mktmpdir do |dir|
  checks = <<~'SH'
    # a comment
    width="$PWD/w"
    export GREETING=hi
    echo "ran $GREETING"; sleep 0.2
    true # trailing note
    ruby -e 'exit 3'
    echo never
  SH
  script = File.join(dir, 'checks.sh')
  generated, = Open3.capture2(RbConfig.ruby, File.join(__dir__, 'timed_checks.rb'), stdin_data: checks)
  File.write(script, generated)
  summary = File.join(dir, 'summary.md')
  File.write(summary, '')
  out, status = Open3.capture2e({ 'GITHUB_STEP_SUMMARY' => summary }, 'bash', '-eo', 'pipefail', '-c', ". #{script}")
  check.call('a failing command still fails the step with its own status', status.exitstatus == 3)
  check.call('the commands after the failure do not run', !out.include?('never'))
  check.call('the commands before it ran in the same shell (variables carried over)', out.include?('ran hi'))
  rows = out[/== check timings[^\n]*\n(.*)\z/m, 1].to_s.lines.map(&:strip)
  check.call('the table lists each timed command, the failed one marked, and a total',
             rows.any? { |r| r.end_with?('sleep 0.2') } && rows.any? { |r| r.include?("FAILED  ruby -e 'exit 3'") } &&
             rows.any? { |r| r.end_with?('true') } && rows.last.end_with?('total'))
  check.call('assignments and comments are not timed', rows.none? { |r| r.include?('export') || r.include?('width=') || r.include?('a comment') })
  seconds = rows[0..-2].map { |r| r.split.first.to_f }
  check.call('slowest first', seconds == seconds.sort.reverse)
  check.call('the table goes to the job summary too', File.read(summary).include?('### Check timings'))
  ok_script = File.join(dir, 'ok.sh')
  File.write(ok_script, Open3.capture2(RbConfig.ruby, File.join(__dir__, 'timed_checks.rb'), stdin_data: "echo one\necho two\n").first)
  out_ok, status_ok = Open3.capture2e('bash', '-eo', 'pipefail', '-c', ". #{ok_script}")
  check.call('a passing block exits 0 and still prints the table', status_ok.success? && out_ok.include?('== check timings') && out_ok.include?('total'))
end

Dir.mktmpdir do |dir|
  checks = "echo run-fixture\nCSEND_MUTANTS=1 echo run-switch\necho mutation_check.rb\nruby x_mutation_check.rb\n"
  generated, = Open3.capture2({ 'CI_SKIP_MUTANTS' => '1' }, RbConfig.ruby, File.join(__dir__, 'timed_checks.rb'), stdin_data: checks)
  script = File.join(dir, 'skip.sh')
  File.write(script, generated)
  out, status = Open3.capture2e('bash', '-eo', 'pipefail', '-c', ". #{script}")
  table = out[/== check timings.*\z/m].to_s
  check.call('CI_SKIP_MUTANTS keeps fixture checks and drops _mutation_check.rb commands',
             status.success? && table.include?('run-fixture') && !table.include?('ruby x_mutation_check.rb'))
  check.call('CI_SKIP_MUTANTS strips the *_MUTANTS=1 switch but still runs the check', table.include?('run-switch') && !table.include?('CSEND_MUTANTS'))
end

# -- parallel groups --------------------------------------------------------------------------------
puts '-- parallel groups'
run_checks = lambda do |dir, text, env = {}|
  generated, gen_status = Open3.capture2(env, RbConfig.ruby, File.join(__dir__, 'timed_checks.rb'), stdin_data: text)
  script = File.join(dir, "g#{rand(1_000_000)}.sh")
  File.write(script, generated)
  out, status = Open3.capture2e('bash', '-eo', 'pipefail', '-c', ". #{script}")
  [out, status, gen_status]
end

Dir.mktmpdir do |dir|
  # Every job logs start and end around a short sleep, so overlap shows in the order of the log, not in wall time.
  trace = File.join(dir, 'trace')
  job = ->(id) { %(echo "start #{id}" >> #{trace}; sleep 0.4; echo "end #{id}" >> #{trace}) }
  body = (1..3).map { |i| job.call(i) }.join("\n")

  File.write(trace, '')
  out, status, = run_checks.call(dir, "who=shell-var\n# ci:parallel begin 3\n#{body}\necho \"sees $who\"\n# ci:parallel end\necho after\n")
  events = File.readlines(trace, chomp: true)
  check.call('a group runs its commands at the same time (all started before the first ended)',
             events.first(3).all? { |e| e.start_with?('start') })
  check.call('a command in a group sees the shell variables set before it', out.include?('sees shell-var'))
  check.call('the command after the group runs once the group is done', status.success? && out.include?('after'))

  File.write(trace, '')
  run_checks.call(dir, "# ci:parallel begin 1\n#{body}\n# ci:parallel end\n")
  events = File.readlines(trace, chomp: true)
  check.call('a group of width 1 never overlaps two commands',
             events.each_slice(2).all? { |s, e| s.start_with?('start') && e == s.sub('start', 'end') })

  File.write(trace, '')
  run_checks.call(dir, "# ci:parallel begin 2\n#{body}\n# ci:parallel end\n")
  events = File.readlines(trace, chomp: true)
  live = 0
  widest = events.map { |e| live += e.start_with?('start') ? 1 : -1 }.max
  check.call('a group never runs more commands than its width (2)', widest == 2)

  out, = run_checks.call(dir, "# ci:parallel begin\necho one\necho two\necho three\n# ci:parallel end\n", { 'CI_PARALLEL_JOBS' => '1' })
  check.call('CI_PARALLEL_JOBS sets the width when the marker has none', out.scan('::group::').size == 3)

  out, status, = run_checks.call(dir, "# ci:parallel begin\necho ok-one\nruby -e 'warn \"boom\"; exit 7'\necho ok-two\n# ci:parallel end\necho never\n")
  check.call('a failing command in a group fails the step with its own status', status.exitstatus == 7)
  check.call('the other commands of the group are still reported, and the failure output is shown',
             out.include?('ok-one') && out.include?('ok-two') && out.include?('boom') && out.include?('FAILED (exit 7'))
  check.call('commands after a failed group do not run', !out.include?('never'))
  table = out[/== check timings.*\z/m].to_s
  check.call('the table lists every command of the group, the failed one marked',
             table.include?("FAILED  ruby -e 'warn") && table.include?('echo ok-one') && table.include?('echo ok-two'))

  out, = run_checks.call(dir, "# ci:parallel begin\necho run-fixture\nruby x_mutation_check.rb\n# ci:parallel end\n", { 'CI_SKIP_MUTANTS' => '1' })
  check.call('CI_SKIP_MUTANTS still drops mutation checks inside a group',
             out.include?('skipping mutants: ruby x_mutation_check.rb') && out.include?('run-fixture'))

  malformed = {
    'a nested begin' => "# ci:parallel begin\n# ci:parallel begin\n",
    'an end with no begin' => "# ci:parallel end\n",
    'a begin with no end' => "# ci:parallel begin\necho a\n",
    'a variable assignment inside a group' => "# ci:parallel begin\nwidth=1\n# ci:parallel end\n"
  }
  malformed.each do |what, text|
    _out, _status, gen_status = run_checks.call(dir, text)
    check.call("#{what} is refused when the script is generated", !gen_status.success?)
  end
end

puts(failures.empty? ? 'ci helpers check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
