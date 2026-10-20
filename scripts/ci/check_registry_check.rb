#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'check_registry'

def expect(label, condition)
  raise label unless condition

  puts "ok #{label}"
end

paths = Set['scripts/bc2cpp/a_check.rb', 'scripts/bc2cpp/b_check.rb']
a, b = paths.to_a
policy = {
  'version' => 1,
  'runners' => { 'coverage' => [], 'bc2cpp-build' => ['mrbc'] },
  'checks' => { a => { 'tier' => 'fast', 'capabilities' => [], 'fixture_capabilities' => ['mrbc'] } },
  'deferred' => { b => { 'tier' => 'review', 'capabilities' => ['git_base'], 'reason' => 'argument-driven audit' } }
}
run = lambda do |coverage: [a], jobs: { 'bc2cpp-build' => [a] }, change: nil|
  config = Marshal.load(Marshal.dump(policy))
  change&.call(config)
  Bc2cppCheckRegistry.audit(discovered: paths, coverage: coverage, jobs: jobs, policy: config)
end
expect('host and full fixture registrations pass', run.call.empty?)
expect('active checks need inspected requirements', run.call(change: ->(c) { c['checks'].clear }).any? { |m| m.include?('unclassified active') })
expect('unregistered checks fail', run.call(change: ->(c) { c['deferred'].clear }).any? { |m| m.include?('unregistered') })
expect('duplicate coverage fails', run.call(coverage: [a, a]).any? { |m| m.include?('duplicate') })
expect('duplicate job invocation fails', run.call(jobs: { 'bc2cpp-build' => [a, a] }).any? { |m| m.include?('duplicate') })
expect('missing check fails', run.call(coverage: ['scripts/bc2cpp/gone_check.rb']).any? { |m| m.include?('missing') })
expect('host-only registration cannot satisfy fixtures', run.call(jobs: {}).any? { |m| m.include?('full fixture') })
expect('incompatible job cannot satisfy fixtures', run.call(jobs: { 'ruby-checks' => [a] }).any? { |m| m.include?('full fixture') })
expect('incompatible host requirements fail', run.call(change: ->(c) { c['checks'][a]['capabilities'] = ['native_sources'] }).any? { |m| m.include?('requires native_sources') })
expect('unknown capabilities fail', run.call(change: ->(c) { c['checks'][a]['capabilities'] = ['typo'] }).any? { |m| m.include?('unknown capabilities') })
expect('misspelled policy keys fail', run.call(change: ->(c) { c['checks'][a]['fixture_capability'] = ['mrbc'] }).any? { |m| m.include?('unknown policy keys') })
expect('overlapping classifications fail', run.call(change: ->(c) { c['checks'][b] = c['deferred'][b] }).any? { |m| m.include?('both active and deferred') })
expect('unknown top-level keys fail', run.call(change: ->(c) { c['typo'] = {} }).any? { |m| m.include?('top-level') })
expect('non-array capabilities fail clearly', run.call(change: ->(c) { c['checks'][a]['capabilities'] = 'mrbc' }).any? { |m| m.include?('array of strings') })
expect('non-string capability entries fail clearly', run.call(change: ->(c) { c['runners']['coverage'] = [nil] }).any? { |m| m.include?('array of strings') })
expect('malformed optional capabilities fail clearly', run.call(change: ->(c) { c['checks'][a]['fixture_capabilities'] = nil }).any? { |m| m.include?('array of strings') })
expect('unexplained optional gates fail', run.call(change: ->(c) { c['checks'][a]['fixture_gate'] = false }).any? { |m| m.include?('needs a reason') })
expect('explained optional fixtures do not schedule work', run.call(jobs: {}, change: ->(c) { c['checks'][a].merge!('fixture_gate' => false, 'reason' => 'budgeted separately') }).empty?)
expect('unknown tiers fail', run.call(change: ->(c) { c['deferred'][b]['tier'] = 'typo' }).any? { |m| m.include?('unknown tier') })
expect('empty reasons fail', run.call(change: ->(c) { c['deferred'][b]['reason'] = '' }).any? { |m| m.include?('reason') })
expect('scheduled deferrals fail', run.call(coverage: [a, b]).any? { |m| m.include?('leave deferred') })
expect('stale deferred paths fail', run.call(change: ->(c) { c['deferred']['scripts/bc2cpp/gone_check.rb'] = c['deferred'][b] }).any? { |m| m.include?('missing check') })
workflow = { 'jobs' => { 'build' => { 'steps' => [{ 'parallel' => [{ 'run' => "# #{a}\nruby #{b}\n" }] }] } } }
expect('nested commands ignore comment references', Bc2cppCheckRegistry.workflow_checks(workflow) == { 'build' => [b] })
expect('repository registry is valid', Bc2cppCheckRegistry.run)
