#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'check_registry'

def expect(label, condition)
  raise label unless condition

  puts "ok #{label}"
end

paths = Set['scripts/bc2cpp/a_check.rb', 'scripts/bc2cpp/b_check.rb']
a, b = paths.to_a
run = lambda do |coverage: [a], jobs: {}, deferred: { b => 'manual fixture' }, fixture_gates: []|
  Bc2cppCheckRegistry.audit(discovered: paths, coverage: coverage, jobs: jobs, deferred: deferred,
                           fixture_gates: fixture_gates)
end
expect('a scheduled check and an explained deferred check pass', run.call.empty?)
expect('new unscheduled checks fail', run.call(deferred: {}).any? { |message| message.include?('unregistered') })
expect('duplicate coverage invocations fail', run.call(coverage: [a, a]).any? { |message| message.include?('duplicate') })
expect('duplicate invocations in one job fail', run.call(jobs: { 'build' => [a, a] }).any? { |message| message.include?('duplicate') })
expect('missing check paths fail', run.call(coverage: ['scripts/bc2cpp/gone_check.rb']).any? { |message| message.include?('missing') })
expect('a host pass and an MRBC pass may share an entrypoint', run.call(jobs: { 'bc2cpp-build' => [a] }).empty?)
expect('coverage alone cannot satisfy a compiler-fixture gate', run.call(fixture_gates: [a]).any? { |message| message.include?('MRBC') })
expect('the compiler job satisfies its fixture gate', run.call(jobs: { 'bc2cpp-build' => [a] }, fixture_gates: [a]).empty?)
expect('empty deferral reasons fail', run.call(deferred: { b => '' }).any? { |message| message.include?('reason') })
workflow = { 'jobs' => { 'build' => { 'steps' => [{ 'parallel' => [{ 'run' => "# #{a}\nruby #{b}\n" }] }] } } }
expect('nested parallel steps are read and comment-only references ignored', Bc2cppCheckRegistry.workflow_checks(workflow) == { 'build' => [b] })
expect('the repository registry is valid', Bc2cppCheckRegistry.run)
