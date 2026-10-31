#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
report = File.join(root, 'scripts/bc2cpp/dynamic_names_report.rb')
Dir.mktmpdir('dynamic-names-report') do |dir|
  preload = File.join(dir, 'analysis.rb')
  calls = File.join(dir, 'calls')
  File.write(preload, <<~'RUBY')
    require 'set'
    module StaticDispatchLists
      PATH_ENV = 'BC2CPP_STATIC_DISPATCH_LISTS'
      def self.current(required:) = :lists
    end
    module StaticDispatchRegistrations
      IDENT = /\A[a-zA-Z_]\w*[!?=]?\z/
      class << self
        attr_accessor :why
      end
      def self.analyze(*)
        File.open(ENV.fetch('REPORT_CALLS'), 'a') { |file| file.puts('analyze') }
        self.why = { 'keep' => 'sent by fixture', 'flag' => 'sent by base name' }
        { registered: ['keep', 'keep', 'pruned', 'flag?', '<=>', 'load_data'].map { |name| { owner: 'Game::Fixture', name: name } },
          dynamic: Set['flag'], fragments: Set['load_'] }
      end
      def self.eligible(*) = [{ owner: 'Game::Fixture', name: 'pruned' }]
      def self.owner_re(*) = /\AGame::/
    end
    $LOADED_FEATURES << File.join(ENV.fetch('REPORT_ROOT'), 'tools/bc2cpp/static_dispatch_registrations.rb')
  RUBY
  env = { 'REPORT_ROOT' => root, 'REPORT_CALLS' => calls, 'BC2CPP_STATIC_DISPATCH_LISTS' => 'fixture.json' }
  run = lambda do |*args|
    File.delete(calls) if File.exist?(calls)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-r', preload, report, *args)
    [stdout, stderr, status, File.exist?(calls) ? File.readlines(calls).size : 0]
  end
  summary, error, status, count = run.call
  abort "summary failed: #{error}" unless status.success? && count == 1 && summary.include?('kept entries: 4 (eligible: 1)')
  entries, error, status, count = run.call('--entries')
  abort "entries failed: #{error}" unless status.success? && count == 1
  expected = [
    "Game::Fixture\t<=>\tnot an identifier (operator names are always dynamic)",
    "Game::Fixture\tflag?\tits base `flag`: sent by base name (SUFFIX_BASES)",
    "Game::Fixture\tkeep\tsent by fixture",
    "Game::Fixture\tload_data\ta string fragment \"load_\" may build it (FRAGMENT_USES)"
  ].join("\n") + "\n"
  abort 'entry filtering, deduplication or reasons changed' unless entries == expected
  output = File.join(dir, 'entry rows.tsv')
  combined, error, status, count = run.call('--entries-out', output)
  abort "combined report failed: #{error}" unless status.success? && count == 1
  abort 'combined summary differs from the default' unless combined == summary
  abort 'combined TSV differs from --entries' unless File.read(output) == entries
  _, error, status, = run.call('--entries-out', File.join(dir, 'missing', 'out.tsv'))
  abort 'unwritable output did not surface a failure' if status.success? || error.empty?
  _, _, status, count = run.call('--unknown')
  abort 'invalid options ran the analysis' if status.success? || count != 0
  puts 'dynamic_names_report_check: output compatibility, single analysis and failures passed'
end
