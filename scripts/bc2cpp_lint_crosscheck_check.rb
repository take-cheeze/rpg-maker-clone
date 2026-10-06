#!/usr/bin/env ruby
# frozen_string_literal: true

# Self-test for tools/bc2cpp/lint_crosscheck.rb (ADR 0368): the real tree agrees with the lint
# baseline, and a lint offence or a lint/analysis disagreement is reported.

require 'tmpdir'
require 'fileutils'
require_relative '../tools/bc2cpp/lint_crosscheck'

ROOT_DIR = File.expand_path('..', __dir__)
Fake = Struct.new(:method_missing_files)
failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

check.call('real tree and an empty analysis agree', LintCrosscheck.violations(ROOT_DIR, Fake.new([])).empty?)

p = LintCrosscheck.violations(ROOT_DIR, Fake.new(['/x/mruby-rgss/mrblib/a.rb']))
check.call('method_missing in a linted file with a clean lint cop is a disagreement', p.one? && p.first.include?('mruby-rgss/mrblib/a.rb'))
check.call('method_missing in a fixture file is outside the lint domain',
           LintCrosscheck.violations(ROOT_DIR, Fake.new(['/tmp/fixture.rb'])).empty?)

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, 'scripts'))
  FileUtils.mkdir_p(File.join(dir, 'mruby-rpg2k/mrblib'))
  FileUtils.cp(File.join(ROOT_DIR, 'scripts/rpg2k_closed_world_lint_baseline.txt'), File.join(dir, 'scripts'))
  File.write(File.join(dir, 'mruby-rpg2k/mrblib/x.rb'), "class X\n  def go(o, n)\n    o.send(n)\n  end\nend\n")
  run = closed_world_lint_run(root: dir)
  check.call('an offence outside the baseline is new', run[:new_offences].any? { |o| o.cop == 'Dynamic/Send' })
  check.call('baseline entries missing from the tree are stale', !run[:stale].empty?)
end

if failures.empty?
  puts 'bc2cpp lint crosscheck check: PASS'
else
  warn "bc2cpp lint crosscheck check: FAIL (#{failures.size})"
  exit 1
end
