#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the mutation harness support (scripts/bc2cpp_mutation_support.rb) with deliberately broken harnesses, so a
# green mutation check cannot be vacuous:
#
#   * a mutant is told apart as killed by its assertion, killed by a crash (reported, not a kill), killed by another
#     assertion, or survived; a timeout and an empty output are crashes;
#   * a control that skipped its run half, asserted nothing, or never reached compiled code is rejected;
#   * a tree outside the repository layout is refused, and a tool copied outside it (an EMPTY closed world) fails the
#     world probe while the repository-layout tree passes it;
#   * a mutant that only breaks the build of the generated C++ is a crash, not a kill, even though the check prints
#     the FAIL line of the assertion it names.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir | BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp_mutation_harness_check.rb
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'bc2cpp_fixture_runtime'
require_relative 'bc2cpp_mutation_support'

Support = Bc2cppMutationSupport
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# A child "check" that prints `script`'s output and exits with `status`; notes are what a fixture run would log.
fake = lambda do |lines, status: 0, notes: [], sleep_for: nil|
  code = +''
  code << "File.write(ENV.fetch('BC2CPP_PROBE_LOG'), #{(notes.join("\n") + "\n").dump})\n" unless notes.empty?
  code << "puts #{lines.join("\n").dump}\n" unless lines.empty?
  code << "$stdout.flush; sleep #{sleep_for}\n" if sleep_for
  code << "exit #{status}\n"
  Support.run_check({}, [RbConfig.ruby, '-e', code], timeout: sleep_for ? 1 : 30)
end
expected = /guards the condition/
verdict = ->(run, baseline: []) { Support.classify(run, expected, baseline: baseline).kind }

puts '-- verdicts'
check.call('the intended assertion fired: killed by assertion',
           verdict.call(fake.call(['  FAIL NEG x guards the condition'], status: 1)) == Support::KILLED_BY_ASSERTION)
check.call('the check passed: survived', verdict.call(fake.call(['  ok   everything'])) == Support::SURVIVED)
check.call('an uncaught exception and no FAIL line: killed by crash',
           verdict.call(fake.call(['bc2cpp.rb failed: boom'], status: 1)) == Support::KILLED_BY_CRASH)
check.call('empty output and a nonzero exit: killed by crash', verdict.call(fake.call([], status: 139)) == Support::KILLED_BY_CRASH)
check.call('a hang: killed by crash (timeout)', verdict.call(fake.call(['  ok   started'], sleep_for: 30)) == Support::KILLED_BY_CRASH)
check.call('another assertion fired: not the intended kill',
           verdict.call(fake.call(['  FAIL something else'], status: 1)) == Support::KILLED_ELSEWHERE)
crashed = fake.call(['  FAIL NEG x guards the condition'], status: 1, notes: ['build-failed'])
check.call('the intended FAIL with a fixture build failure behind it: killed by crash',
           verdict.call(crashed) == Support::KILLED_BY_CRASH)
check.call('the same crash in the control run is the check\'s own baseline: killed by assertion',
           verdict.call(crashed, baseline: ['build-failed']) == Support::KILLED_BY_ASSERTION)
check.call('a crash kill does not count unless the harness declares it acceptable',
           !Support.killed?(Support::Verdict.new(Support::KILLED_BY_CRASH, 'x')) &&
             Support.killed?(Support::Verdict.new(Support::KILLED_BY_CRASH, 'x'), crash_ok: true))
check.call('a mutant without its label is refused', begin
  Support.classify(fake.call([]), nil)
  false
rescue ArgumentError
  true
end)

puts '-- the control'
oks = (1..6).map { |i| "  ok   case #{i}" }
check.call('a passing control with enough ok lines is usable', Support.control_problems(fake.call(oks), run_half: false).empty?)
check.call('a control that asserted almost nothing is refused', !Support.control_problems(fake.call(oks.first(1)), run_half: false).empty?)
check.call('a failing control is refused', !Support.control_problems(fake.call(oks + ['  FAIL x'], status: 1), run_half: false).empty?)
check.call('a control that skipped its run half is refused',
           !Support.control_problems(fake.call(oks + ['-- SKIP run: set MRBC']), run_half: true).empty?)
check.call('a run half that never reached compiled code is refused',
           !Support.control_problems(fake.call(oks, notes: ['compiled-hits 0 []']), run_half: true).empty? &&
             !Support.control_problems(fake.call(oks), run_half: true).empty?)
check.call('a run half whose compiled VM dispatched into compiled code is usable',
           Support.control_problems(fake.call(oks, notes: ['compiled-hits 7 []']), run_half: true).empty?)
check.call('a parent MUTANTS/TOOL variable does not reach a child (no recursive harness, no wrong tool)', begin
  saved = ENV.values_at('FOO_MUTANTS', 'BC2CPP_TOOL')
  ENV['FOO_MUTANTS'] = '1'
  ENV['BC2CPP_TOOL'] = '/nowhere'
  run = Support.run_check({}, [RbConfig.ruby, '-e', 'puts [ENV["FOO_MUTANTS"], ENV["BC2CPP_TOOL"]].inspect'])
  run.out.include?('[nil, nil]')
ensure
  ENV['FOO_MUTANTS'], ENV['BC2CPP_TOOL'] = saved
end)

puts '-- the tree'
check.call('a tree is the repository layout', Support.with_tree([]) { |tree| File.expand_path('../..', tree.tool) == tree.dir })
check.call('a mutation site that is gone yields no tree',
           Support.with_tree([['bc2cpp.rb', 'no such text anywhere', 'x']]) { :ran }.nil?)
check.call('a tree outside the layout is refused', begin
  Dir.mktmpdir do |outside|
    FileUtils.cp_r(File.join(Support::ROOT, 'tools/bc2cpp'), outside)
    Support.layout!(Support::Tree.new(outside, File.join(outside, 'bc2cpp')))
  end
  false
rescue Support::LayoutError
  true
end)

puts '-- the closed world'
if ENV['MRBC']
  check.call('the repository-layout tree reads the real closed world', Support.with_tree([]) { |tree| Support.world_problems(tree).empty? })
  # The old harnesses copied the generator to a temp dir: bc2cpp.rb then finds no engine sources and reads a smaller world.
  Dir.mktmpdir do |outside|
    FileUtils.cp_r(File.join(Support::ROOT, 'tools/bc2cpp'), outside)
    problems = Support.world_problems(Support::Tree.new(outside, File.join(outside, 'bc2cpp')))
    check.call("a tool copied outside the repository reads an empty world, so its control fails (#{problems.first.to_s[0, 90]})",
               !problems.empty?)
  end
else
  puts '  SKIP: set MRBC'
end

puts '-- a mutant that only breaks the build'
build = Bc2cppFixtureRuntime.core || Bc2cppFixtureRuntime.full
if ENV['MRBC'] && build && Bc2cppFixtureRuntime.compiler?
  Dir.mktmpdir do |dir|
    # The mutant: the real generator with an #error appended to its C++. The fake check prints, like the real ones, the
    # FAIL line of the assertion it names whenever the compiled answers are not the interpreter's.
    real = File.join(Support::ROOT, 'tools/bc2cpp/bc2cpp.rb')
    shim = File.join(dir, 'bc2cpp.rb')
    File.write(shim, <<~RUBY)
      require 'open3'
      out, status = Open3.capture2(RbConfig.ruby, #{real.dump}, *ARGV, err: $stderr)
      print out, "\\n#error mutant\\n"
      exit status.exitstatus
    RUBY
    script = File.join(dir, 'fake_check.rb')
    File.write(script, <<~RUBY)
      require #{File.join(Support::ROOT, 'scripts/bc2cpp_fixture_runtime').dump}
      rt = Bc2cppFixtureRuntime
      Dir.mktmpdir do |d|
        _code, err = rt.generate("class MhProbe\\n  def one; 1; end\\nend\\n", d, only_owners: %w[MhProbe])
        body = 'static int scenario(mrb_state* M) { call(M, "one", mrb_obj_new(M, mrb_class_get(M, "MhProbe"), 0, nullptr), "one"); return 0; }'
        built, out = rt.run(d, err, %w[MhProbe], body, build: #{build.dump}, full: #{(build == Bc2cppFixtureRuntime.full).inspect})
        s = built ? rt.sections(out) : {}
        same = built && !s.fetch('interpreted', []).empty? && s['interpreted'].reject { |l| l.start_with?('  dispatches') } ==
                                                          s.fetch('compiled', []).reject { |l| l.start_with?('  dispatches') }
        puts "  \#{same ? 'ok  ' : 'FAIL'} every method answers what the interpreter answers"
        exit(same ? 0 : 1)
      end
    RUBY
    run = ->(tool) { Support.run_check({ 'BC2CPP_TOOL' => tool, 'MRBC' => ENV.fetch('MRBC') }, [RbConfig.ruby, script]) }
    clean = run.call(real)
    check.call('the unmutated fake check passes and its compiled VM dispatched into compiled code',
               clean.success && clean.notes.grep(/\Acompiled-hits [1-9]/).any?)
    broken = Support.classify(run.call(shim), /every method answers what the interpreter answers/, baseline: clean.notes)
    check.call("an #error in the generated C++ is a crash, not a kill (#{broken.reason[0, 70]})", broken.kind == Support::KILLED_BY_CRASH)
  end
else
  puts '  SKIP: needs MRBC, a mruby build (BC2CPP_MRUBY_CORE or _FULL) and g++'
end

if failures.empty?
  puts 'bc2cpp mutation harness check: PASS'
else
  warn "bc2cpp mutation harness check: #{failures.size} failure(s)"
  exit 1
end
