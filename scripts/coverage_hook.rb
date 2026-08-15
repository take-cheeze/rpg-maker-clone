#!/usr/bin/env ruby
# encoding: UTF-8
#
# Line-coverage collector, injected into a check process by
# scripts/coverage_report.rb. Not meant to be run by hand.
#
# The engine's game logic is Ruby that runs inside mruby in the shipped binary,
# but every `scripts/*_check.rb` harness loads those same sources under CRuby
# (see the header of any of them), so CRuby's own `Coverage` stdlib is what can
# measure them. Coverage has to be started *before* the sources are loaded,
# which is why this file is injected with `RUBYOPT=-r...` instead of being
# required from the harnesses: the harnesses stay untouched, and any `ruby` a
# harness spawns is measured too.
#
# Each process writes its own result as JSON into $RPG_COVERAGE_DIR; the
# reporter merges them. Nothing else is defined at top level here — the file is
# loaded into somebody else's process, so it must not add names to it.

require 'coverage'

Coverage.start(lines: true)

at_exit do
  dir = ENV['RPG_COVERAGE_DIR'].to_s
  # No directory means nobody asked for coverage (a stray RUBYOPT, say), which
  # is not an error — just nothing to write.
  next if dir.empty?

  begin
    require 'json'

    root = File.expand_path('..', __dir__) + File::SEPARATOR
    # `stop: false`/`clear: false`: another at_exit handler registered later
    # still runs after this one and its lines should keep being counted, even
    # though nothing will read them.
    result = Coverage.running? ? Coverage.result(stop: false, clear: false) : {}

    lines = result.each_with_object({}) do |(path, cov), acc|
      # Only the repository's own sources; the stdlib and the gems it pulls in
      # are not what this measures.
      next unless path.start_with?(root)

      counts = cov.is_a?(Hash) ? cov[:lines] : cov
      acc[path[root.length..-1]] = counts if counts
    end

    tag = ENV['RPG_COVERAGE_TAG'].to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
    tag = 'check' if tag.empty?
    # pid alone is not unique across a whole run (they are recycled between
    # sequential checks) and a harness may spawn nested ruby processes, so add
    # a random suffix. Drawing from the default RNG here is safe: at_exit runs
    # after the harness has finished with it.
    name = format('%s-%d-%08x.json', tag, Process.pid, Random.rand(0xffff_ffff))
    File.write(File.join(dir, name), JSON.generate(lines))
  rescue StandardError => e
    # Losing coverage must not be silent, and must not change the exit status
    # of the check that was being measured.
    warn "[coverage] could not record #{$PROGRAM_NAME}: #{e.class}: #{e.message}"
  end
end
