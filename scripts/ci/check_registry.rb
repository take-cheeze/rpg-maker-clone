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
  TIERS = %w[fast runtime mutation review].freeze
  CAPABILITIES = %w[mrbc native_sources core_library full_library cxx git_base closed_build clang].freeze

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

  def validate_policy(policy)
    return ['policy must be a mapping'] unless policy.is_a?(Hash)

    errors = []
    unknown = policy.keys - %w[version runners checks deferred]
    errors << "unknown top-level policy keys: #{unknown.join(', ')}" unless unknown.empty?
    errors << 'unsupported policy version' unless policy['version'] == 1
    %w[runners checks deferred].each do |section|
      errors << "#{section}: expected a mapping" unless policy[section].is_a?(Hash)
    end
    return errors unless errors.empty?

    capability_array = lambda do |label, value|
      if !value.is_a?(Array) || !value.all? { |entry| entry.is_a?(String) }
        errors << "#{label}: capabilities must be an array of strings"
      elsif !(value - CAPABILITIES).empty?
        errors << "#{label}: unknown capabilities #{(value - CAPABILITIES).join(', ')}"
      end
    end
    policy['runners'].each { |runner, capabilities| capability_array.call(runner, capabilities) }
    %w[checks deferred].each do |section|
      policy[section].each do |path, metadata|
        unless metadata.is_a?(Hash)
          errors << "#{path}: expected a metadata mapping"
          next
        end
        unknown = metadata.keys - %w[tier capabilities fixture_capabilities fixture_gate host_phase reason]
        errors << "#{path}: unknown policy keys #{unknown.join(', ')}" unless unknown.empty?
        capability_array.call(path, metadata['capabilities'])
        capability_array.call("#{path} fixture", metadata['fixture_capabilities']) if metadata.key?('fixture_capabilities')
        if metadata.key?('fixture_gate') && ![true, false].include?(metadata['fixture_gate'])
          errors << "#{path}: fixture_gate must be true or false"
        end
        if metadata.key?('host_phase') && ![true, false].include?(metadata['host_phase'])
          errors << "#{path}: host_phase must be true or false"
        end
        if metadata['fixture_gate'] == false && metadata['reason'].to_s.strip.empty?
          errors << "#{path}: optional fixture gate needs a reason"
        end
      end
    end
    errors
  end

  def audit(discovered:, coverage:, jobs:, policy:)
    errors = validate_policy(policy)
    return errors unless errors.empty?

    runners = policy.fetch('runners')
    deferred = policy.fetch('deferred')
    fixtures = policy.fetch('checks')
    { 'coverage' => coverage, **jobs }.each do |where, paths|
      paths.tally.each do |path, count|
        errors << "#{where}: missing check #{path}" unless discovered.include?(path)
        errors << "#{where}: duplicate check #{path} (#{count} registrations)" if count > 1
      end
    end
    scheduled = (coverage + jobs.values.flatten).to_set
    (discovered - scheduled - deferred.keys.to_set).sort.each { |path| errors << "unregistered check #{path}" }
    (scheduled - fixtures.keys.to_set).sort.each { |path| errors << "unclassified active check #{path}" }
    runners.each do |runner, capabilities|
      errors << "#{runner}: unknown capabilities" unless (capabilities - CAPABILITIES).empty?
    end
    (deferred.keys & fixtures.keys).each { |path| errors << "#{path}: both active and deferred policy" }
    { **deferred, **fixtures }.each do |path, metadata|
      errors << "policy: missing check #{path}" unless discovered.include?(path)
      errors << "#{path}: unknown tier" unless TIERS.include?(metadata['tier'])
      capabilities = metadata.fetch('capabilities')
      fixture_capabilities = metadata.fetch('fixture_capabilities', [])
      errors << "#{path}: unknown capabilities" unless ((capabilities + fixture_capabilities) - CAPABILITIES).empty?
      { 'coverage' => coverage, **jobs }.each do |runner, paths|
        next unless paths.include?(path)

        available = runners.fetch(runner, [])
        missing = capabilities - available
        errors << "#{runner}: #{path} requires #{missing.join(', ')}" unless missing.empty?
      end
      next if fixture_capabilities.empty? || metadata['fixture_gate'] == false

      complete = jobs.any? do |runner, paths|
        paths.include?(path) && ((capabilities + fixture_capabilities) - runners.fetch(runner, [])).empty?
      end
      errors << "full fixture coverage missing: #{path}" unless complete
    end
    deferred.each do |path, metadata|
      errors << "#{path}: deferred check needs a reason" if metadata['reason'].to_s.strip.empty?
      errors << "#{path}: scheduled check must leave deferred inventory" if scheduled.include?(path)
    end
    errors
  end

  def inventory(root = ROOT)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(root, 'scripts/coverage/report.rb'), '--list')
    raise "coverage registry listing failed: #{stderr}" unless status.success?

    coverage = stdout.scan(PATH_PATTERN)
    jobs = workflow_checks(YAML.load_file(File.join(root, '.github/workflows/build.yml')))
    discovered = Dir.chdir(root) { Dir['scripts/bc2cpp/*_check.rb'].to_set }
    policy = YAML.load_file(File.join(root, 'scripts/ci/bc2cpp_check_policy.yml'))
    [discovered, coverage, jobs, policy]
  end

  def run(root = ROOT)
    discovered, coverage, jobs, policy = inventory(root)
    schema_errors = validate_policy(policy)
    unless schema_errors.empty?
      schema_errors.each { |error| warn "check registry: #{error}" }
      return false
    end
    errors = audit(discovered: discovered, coverage: coverage, jobs: jobs, policy: policy)
    errors.each { |error| warn "check registry: #{error}" }
    puts "bc2cpp registry: #{discovered.size} checks, #{policy.fetch('deferred').size} explicitly deferred"
    policy.fetch('deferred').sort.each do |path, metadata|
      puts "  #{metadata.fetch('tier')} #{path} [#{metadata.fetch('capabilities').join(', ')}]: #{metadata.fetch('reason')}"
    end
    active = (coverage + jobs.values.flatten).to_set
    unclassified = active - policy.fetch('checks').keys.to_set
    puts "  #{unclassified.size} active checks have unclassified requirements:"
    unclassified.sort.each { |path| puts "    unclassified #{path}" }
    policy.fetch('checks').sort.each do |path, metadata|
      requirements = metadata.fetch('capabilities') + metadata.fetch('fixture_capabilities', [])
      complete = jobs.any? { |runner, paths| paths.include?(path) && (requirements - policy.fetch('runners').fetch(runner, [])).empty? }
      state = if complete
                'workflow complete'
              elsif metadata.fetch('fixture_capabilities', []).empty?
                'host complete'
              else
                'host slice only; optional fixture not guaranteed by declared runners'
              end
      state += '; host registration skips' if metadata['host_phase'] == false
      puts "  #{metadata.fetch('tier')} #{path} [host: #{metadata.fetch('capabilities').join(', ')}; fixture: #{metadata.fetch('fixture_capabilities', []).join(', ')}] #{state}"
    end
    errors.empty?
  end
end

exit(Bc2cppCheckRegistry.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
