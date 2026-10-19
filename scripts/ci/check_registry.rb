#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'set'
require 'yaml'

# Read the actual runner lists; a second execution manifest would drift from them.
module Bc2cppCheckRegistry
  ROOT = File.expand_path('../..', __dir__)
  PATH_PATTERN = %r{scripts/bc2cpp/[a-zA-Z0-9_]+_check\.rb}
  FIXTURE_GATES = %w[block_receiver_proof ir_context_results ir_argument_types ir_ivar_types ir_soundness_classes
                    numeric_roots_reaching ir_block_protocols].map { |name| "scripts/bc2cpp/#{name}_check.rb" }.freeze

  module_function

  def commands(value)
    case value
    when Hash
      value.flat_map { |key, child| key == 'run' ? [child] : commands(child) }
    when Array
      value.flat_map { |child| commands(child) }
    else
      []
    end
  end

  def workflow_checks(workflow)
    workflow.fetch('jobs').to_h do |name, job|
      shell = commands(job).join("\n").lines.reject { |line| line.lstrip.start_with?('#') }.join
      [name, shell.scan(PATH_PATTERN)]
    end
  end

  def audit(discovered:, coverage:, jobs:, deferred:, fixture_gates: FIXTURE_GATES)
    errors = []
    { 'coverage' => coverage, **jobs }.each do |where, paths|
      paths.tally.each do |path, count|
        errors << "#{where}: missing check #{path}" unless discovered.include?(path)
        errors << "#{where}: duplicate check #{path} (#{count} registrations)" if count > 1
      end
    end
    scheduled = (coverage + jobs.values.flatten).to_set
    (discovered - scheduled - deferred.keys.to_set).sort.each { |path| errors << "unregistered check #{path}" }
    deferred.each { |path, reason| errors << "#{path}: deferred check needs a reason" if reason.to_s.strip.empty? }
    fixture_gates.each do |path|
      errors << "MRBC fixture missing from bc2cpp-build: #{path}" unless jobs.fetch('bc2cpp-build', []).include?(path)
    end
    errors
  end

  def inventory(root = ROOT)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(root, 'scripts/coverage/report.rb'), '--list')
    raise "coverage registry listing failed: #{stderr}" unless status.success?

    coverage = stdout.scan(PATH_PATTERN)
    jobs = workflow_checks(YAML.load_file(File.join(root, '.github/workflows/build.yml')))
    discovered = Dir.chdir(root) { Dir['scripts/bc2cpp/*_check.rb'].to_set }
    deferred = YAML.load_file(File.join(root, 'scripts/ci/deferred_bc2cpp_checks.yml'))
    [discovered, coverage, jobs, deferred]
  end

  def run(root = ROOT)
    discovered, coverage, jobs, deferred = inventory(root)
    gates = FIXTURE_GATES + (discovered.include?('scripts/bc2cpp/ir_blocks_check.rb') ? ['scripts/bc2cpp/ir_blocks_check.rb'] : [])
    errors = audit(discovered: discovered, coverage: coverage, jobs: jobs, deferred: deferred, fixture_gates: gates)
    errors.each { |error| warn "check registry: #{error}" }
    unscheduled = discovered - (coverage + jobs.values.flatten).to_set
    puts "bc2cpp registry: #{discovered.size} checks, #{unscheduled.size} explicitly deferred"
    unscheduled.sort.each { |path| puts "  deferred #{path}: #{deferred[path]}" }
    puts 'Selected MRBC fixture gates require bc2cpp-build; coverage-only registration does not satisfy them'
    errors.empty?
  end
end

exit(Bc2cppCheckRegistry.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
