# frozen_string_literal: true

# Shared by the bc2cpp mutation checks (docs/ci.md, "Mutation harnesses"). A mutation check is only worth its
# green line if a mutant that dies did so for the reason it names, and if the unmutated run proves the world it
# mutates is real. Three ways it was not:
#
#   * a mutant tree outside the repository layout reads an EMPTY closed world (bc2cpp.rb finds the engine's sources
#     from its own location, ../..), so mutants "die" because no proof can be made at all;
#   * a mutant that breaks the build or crashes the fixture binary makes the check print FAIL for a reason that is not
#     the soundness condition under test (or no FAIL at all, which a loose `!success` counts as a kill);
#   * with no control run, nothing says the check passes on the unmutated generator in that same layout.
#
# This module gives every harness the same three answers: a tree that is checked to be the repository layout and to
# read the same closed world as the real tool (`with_tree`, `world_problems`), a control run that must pass and
# prove it ran what it claims (`control_problems`), and a verdict per mutant that keeps a kill by the intended
# assertion apart from a kill by a crash (`classify`). Evidence from the fixture runs comes through
# BC2CPP_PROBE_LOG (scripts/bc2cpp_fixture_runtime.rb).
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'bc2cpp_mutant_pool'

module Bc2cppMutationSupport
  ROOT = File.expand_path('..', __dir__)
  MUTANT_ROOT = File.join(ROOT, '.mutants')

  KILLED_BY_ASSERTION = :killed_by_assertion
  KILLED_BY_CRASH = :killed_by_crash
  KILLED_ELSEWHERE = :killed_elsewhere
  SURVIVED = :survived

  Verdict = Struct.new(:kind, :reason)
  # `notes`: the BC2CPP_PROBE_LOG lines the run wrote.
  Run = Struct.new(:out, :success, :stopped, :timed_out, :notes)
  Tree = Struct.new(:dir, :tool)
  # `edits`: [[file, pattern, replacement], ...] relative to tools/bc2cpp. `expected`: a Regexp the FAIL line of the
  # assertion that guards the condition matches. `needs_run`: only the check's compiled-versus-interpreted half can
  # kill it. `crash_ok`: a crash of the fixture is how this mutant legitimately shows (the wrong code reads the wrong
  # object), declared per mutant. `scripts`: the check loads the tool by relative path, so scripts/ is copied too.
  Mutant = Struct.new(:name, :edits, :expected, :needs_run, :crash_ok, :scripts, keyword_init: true) do
    # The pool stops a mutant at the FAIL line that already proves it caught.
    def stop_on
      expected && /^\s+FAIL .*(?:#{expected.source})/
    end
  end

  class LayoutError < StandardError; end

  # Evidence lines that mean a fixture build or binary did not finish cleanly.
  CRASH_NOTE = /\A(?:build-failed|binary-failed)/
  # A variable of the caller's environment that would change what a child check runs; each is set explicitly or not at all.
  LEAKY_ENV = /(?:_GENERATED_ONLY|_MUTANTS?|_TOOL|_TOOL_DIR|_TOOLS_DIR|PROBE_LOG|PROBE_FILE)\z/
  WORLD_LINE = /== closed world \(wio: (\d+) gems, (\d+) native \+ (\d+) Ruby outside sources\) ==/
  WORLD_PROBE = <<~'RUBY'
    require 'tmpdir'
    require ARGV.fetch(0)
    Dir.mktmpdir do |dir|
      _code, err = Bc2cppFixtureRuntime.generate("class WorldProbe\n  def x; 1; end\nend\n", dir, only_owners: %w[WorldProbe])
      puts err.lines.grep(/== closed world \(/)
    end
  RUBY

  module_function

  # BC2CPP_MUTATION_VERBOSE=1 lists every FAIL line of every mutant, and lets a mutant lack its `expected` label so
  # the label can be read off (such a mutant never counts as killed).
  def discovery?
    ENV['BC2CPP_MUTATION_VERBOSE'] == '1'
  end

  def timeout
    value = ENV.fetch('BC2CPP_MUTANT_TIMEOUT', nil)
    value.nil? || value.empty? ? 1200 : Float(value)
  end

  # -- the mutant tree --------------------------------------------------------------------------

  # A copy of tools/bc2cpp with `edits` ([file, pattern, replacement], file relative to tools/bc2cpp) applied, placed
  # so that its own ../.. is the repository itself (.mutant<id>/bc2cpp): the closed world then reads the very paths
  # the check hands the real tool. With `scripts`, the check loads the tool by relative path, so a tree is built that
  # has the repository's layout instead (every other entry linked, scripts/ and tools/bc2cpp copied).
  # Yields a Tree; returns nil, yielding nothing, when a mutation site is gone.
  def with_tree(edits, scripts: false)
    # Directly under the repository: the tool's ../.. is then the repository. A scripts tree is a whole copy of it.
    dir = scripts ? Dir.mktmpdir('m', FileUtils.mkdir_p(MUTANT_ROOT).first) : Dir.mktmpdir('.mutant', ROOT)
    begin
      tree = scripts ? layout_tree(dir) : Tree.new(dir, File.join(dir, 'bc2cpp'))
      FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.dirname(tree.tool)) unless scripts
      FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.join(dir, 'tools')) if scripts
      return nil unless apply(edits, tree.tool)

      layout!(tree, scripts)
      yield tree
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # `dir` as a copy of the repository layout: everything linked but scripts/ (copied) and tools/bc2cpp (copied after).
  def layout_tree(dir)
    (Dir.children(ROOT) - %w[.git .mutants tools scripts]).each { |entry| FileUtils.ln_s(File.join(ROOT, entry), File.join(dir, entry)) }
    FileUtils.cp_r(File.join(ROOT, 'scripts'), dir)
    FileUtils.mkdir_p(File.join(dir, 'tools'))
    (Dir.children(File.join(ROOT, 'tools')) - ['bc2cpp']).each do |entry|
      FileUtils.ln_s(File.join(ROOT, 'tools', entry), File.join(dir, 'tools', entry))
    end
    Tree.new(dir, File.join(dir, 'tools', 'bc2cpp'))
  end

  # False when a pattern is not in its file (the tree is then discarded, so a partly applied mutant never runs).
  def apply(edits, tool)
    edits.all? do |file, pattern, replacement|
      path = File.join(tool, file)
      text = File.read(path)
      text.include?(pattern) && File.write(path, text.sub(pattern) { replacement })
    end
  end

  # The tool must find the repository from its own location: ../.. is the repository itself (or, for a `scripts` tree,
  # a copy that holds every entry of it).
  def layout!(tree, scripts = false)
    world = File.expand_path('../..', tree.tool)
    missing = Dir.children(ROOT) - Dir.children(world) - %w[.git .mutants]
    return if (scripts ? world == tree.dir && missing.empty? : world == ROOT) && Dir.exist?(File.join(world, '3rd/mruby/src'))

    raise LayoutError, "mutant tree #{world} is not the repository layout (missing: #{missing.join(', ')})"
  end

  # -- the closed world the tool reads -----------------------------------------------------------

  # [gems, native, ruby] the real tool counts for the build the fixtures use, from the same functions bc2cpp.rb calls.
  def expected_world
    @expected_world ||= begin
      require_relative '../tools/bc2cpp/compiled_gems'
      require_relative '../tools/bc2cpp/nomethod_reviewed_probe'
      gems = NomethodReviewedProbe.wio_gems(ROOT)
      native, ruby = bc2cpp_closed_world_outside_srcs('wio', gems, ROOT)
      [gems.size, native.size, ruby.size]
    end
  end

  # [gems, native, ruby] that `tool` (a bc2cpp.rb path) reports for a one-class fixture; nil without the line.
  def world_of(tool)
    env = clean_env({ 'BC2CPP_TOOL' => tool, 'MRBC' => ENV.fetch('MRBC', nil) })
    out, err, status = Open3.capture3(env, RbConfig.ruby, '-e', WORLD_PROBE, File.join(ROOT, 'scripts/bc2cpp_fixture_runtime.rb'))
    return [nil, "world probe failed:\n#{(err.empty? ? out : err).lines.last(6).join}"] unless status.success?

    match = WORLD_LINE.match(out)
    match ? [match.captures.map(&:to_i), nil] : [nil, "no closed world line in: #{out.lines.first(3).join}"]
  end

  # Problems that make `tree`'s world differ from the real one (an empty or partial closed world makes every mutant die).
  def world_problems(tree)
    world, problem = world_of(File.join(tree.tool, 'bc2cpp.rb'))
    return [problem] unless world
    return [] if world == expected_world

    ["the closed world is #{world.inspect} (gems, native, Ruby sources), the repository's is #{expected_world.inspect}"]
  end

  # -- running a check ---------------------------------------------------------------------------

  # `env` over the caller's environment minus everything that would steer the child (LEAKY_ENV), so a harness that is
  # itself run with a *_MUTANTS or *_TOOL variable never re-runs itself or tests the wrong tool.
  def clean_env(env)
    ENV.keys.grep(LEAKY_ENV).to_h { |name| [name, nil] }.merge(env)
  end

  # Runs argv with `env`; the fixture runs inside it append their evidence to a private BC2CPP_PROBE_LOG.
  def run_check(env, argv, stop_on: nil, timeout: self.timeout)
    Dir.mktmpdir('probe') do |scratch|
      log = File.join(scratch, 'notes')
      result = Bc2cppMutantPool.run(clean_env(env.merge('BC2CPP_PROBE_LOG' => log)), argv, stop_on: stop_on, timeout: timeout)
      notes = File.exist?(log) ? File.readlines(log, chomp: true) : []
      Run.new(result.out, result.success, result.stopped, result.timed_out, notes)
    end
  end

  def fail_lines(run)
    run.out.lines.grep(/^\s+FAIL /)
  end

  def ok_lines(run)
    run.out.lines.grep(/^\s+ok   /)
  end

  # -- the control -------------------------------------------------------------------------------

  # What an unmutated run must show before any mutant's death means anything. `run_half`: the check was asked to run
  # its compiled-versus-interpreted half, so it must not have skipped it and the compiled VM must have dispatched
  # into compiled code at least once.
  def control_problems(run, run_half:, min_ok: 5)
    problems = []
    problems << "the check fails: #{(fail_lines(run).first(3) + run.out.lines.last(3)).join.strip}" unless run.success
    problems << "the check printed #{ok_lines(run).size} ok lines, fewer than #{min_ok} (it asserted almost nothing)" if ok_lines(run).size < min_ok
    if run_half
      skipped = run.out.lines.grep(/^\s*(?:--\s*)?SKIP/)
      problems << "the run half was skipped: #{skipped.first.strip}" unless skipped.empty?
      hits = run.notes.filter_map { |note| note[/\Acompiled-hits (\d+)/, 1]&.to_i }
      problems << 'no compiled VM ran: the control wrote no compiled-hits evidence' if hits.empty?
      problems << 'the compiled VM never dispatched into a compiled entry' if !hits.empty? && hits.sum.zero?
    end
    problems
  end

  # -- the verdict -------------------------------------------------------------------------------

  def crash_notes(run, baseline)
    allowed = baseline.grep(CRASH_NOTE).tally
    run.notes.grep(CRASH_NOTE).reject do |note|
      next false unless allowed.fetch(note, 0).positive?

      allowed[note] -= 1
      true
    end
  end

  # `expected`: a Regexp the FAIL line of the intended assertion matches. `baseline`: the control's notes, so a crash
  # the check always has (a scenario that is meant to crash) is not held against a mutant.
  def classify(run, expected, baseline: [])
    raise ArgumentError, 'a mutant needs the label of the assertion that guards its condition' if expected.nil? && !discovery?

    expected ||= /(?!)/
    return Verdict.new(KILLED_BY_CRASH, "timed out after #{timeout.to_i}s") if run.timed_out
    return Verdict.new(SURVIVED, 'the check passed against the mutant') if run.success

    failed = fail_lines(run)
    matched = failed.find { |line| line.match?(expected) }
    crashes = crash_notes(run, baseline)
    if matched && crashes.empty?
      Verdict.new(KILLED_BY_ASSERTION, matched.strip)
    elsif matched
      Verdict.new(KILLED_BY_CRASH, "#{crashes.first} (the assertion #{matched.strip.inspect} may be its symptom)")
    elsif failed.empty?
      Verdict.new(KILLED_BY_CRASH, crashes.first || "no FAIL line; last output: #{run.out.lines.last.to_s.strip.inspect}")
    else
      Verdict.new(KILLED_ELSEWHERE, "a different assertion fired: #{failed.first.strip}")
    end
  end

  # A mutant's death counts when the intended assertion fired, or a crash fired and the harness accepts crash kills.
  def killed?(verdict, crash_ok: false)
    verdict.kind == KILLED_BY_ASSERTION || (verdict.kind == KILLED_BY_CRASH && crash_ok)
  end

  # Prints the mutant's line the way the harnesses always have (`ok   mutant killed: name`); true when it counts.
  def report(name, verdict, crash_ok: false)
    if killed?(verdict, crash_ok: crash_ok)
      puts "  ok   mutant killed#{verdict.kind == KILLED_BY_CRASH ? ' (crash accepted)' : ''}: #{name}"
      return true
    end
    label = { KILLED_BY_CRASH => 'mutant only crashed, which is not a kill',
              KILLED_ELSEWHERE => 'mutant died on another assertion',
              SURVIVED => 'mutant survived' }.fetch(verdict.kind)
    puts "  FAIL #{label}: #{name}\n         #{verdict.reason}"
    false
  end

  # The control's line; true when it passes.
  def report_control(name, problems, run)
    if problems.empty?
      puts "  ok   #{name} passes (#{ok_lines(run).size} ok lines)"
      return true
    end
    puts "  FAIL #{name} is not a usable control:\n         #{problems.join("\n         ")}"
    false
  end

  # -- the whole harness -------------------------------------------------------------------------

  # Runs the unmutated control and every mutant through the pool and reports each in input order; returns the names
  # that failed. The block gets (tree, mutant, run_half) (mutant is nil for the control) and returns a Run from
  # `run_check`; `run_half` says whether to run the compiled-versus-interpreted half, which the control does when
  # any mutant needs it and then must prove ran (see `control_problems`).
  def run_harness(mutants, min_ok: 5, &run_in)
    run_half = mutants.any?(&:needs_run)
    expected_world
    failures = []
    baseline = []
    kinds = Hash.new(0)
    seconds = []
    Bc2cppMutantPool.each_ordered([nil] + mutants, work: ->(mutant) { run_one(mutant, run_half, &run_in) }) do |mutant, result|
      if result.nil?
        puts "  FAIL #{mutant.name}: a mutation site is gone from #{mutant.edits.map(&:first).uniq.join(', ')}"
        failures << mutant.name
        next
      end
      run, world_problems, elapsed = result
      seconds << elapsed.round
      if mutant.nil?
        problems = world_problems + control_problems(run, run_half: run_half, min_ok: min_ok)
        failures << 'control' unless report_control('unmutated control', problems, run)
        baseline = run.notes
        next
      end
      verdict = classify(run, mutant.expected, baseline: baseline)
      kinds[verdict.kind] += 1
      failures << mutant.name unless report(mutant.name, verdict, crash_ok: mutant.crash_ok)
      # While writing the `expected` label of a new mutant: every FAIL line (and note) the mutant caused.
      puts "         #{fail_lines(run).join('         ')}#{run.notes.join("\n         ")}" if discovery?
    end
    puts "  mutants: #{kinds.map { |kind, n| "#{n} #{kind.to_s.tr('_', ' ')}" }.join(', ')}; " \
         "runs took #{seconds.minmax.join('-')} s each (BC2CPP_JOBS=#{Bc2cppMutantPool.jobs})"
    failures
  end

  # [run, world problems, seconds] of the control (nil) or one mutant; nil when a mutation site is gone.
  def run_one(mutant, run_half, &run_in)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = with_tree(mutant ? mutant.edits : [], scripts: mutant ? mutant.scripts : false) do |tree|
      [run_in.call(tree, mutant, mutant ? mutant.needs_run : run_half), mutant ? [] : world_problems(tree)]
    end
    result && [*result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end
end
