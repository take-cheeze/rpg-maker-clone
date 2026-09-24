#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs the wio-only mrblib rewrites (strip_wio_rgss_probes.rb,
# strip_wio_inline_helpers.rb, strip_wio_clock.rb, then
# strip_wio_debug_output.rb) over every mrblib file, chained in the order
# build_config.rb's wio_strip_* filters apply them. Each script raises when a
# pattern no longer matches its source, but only a MRUBY_TARGET=wio build ran
# them, and no CI job builds wio, so a source edit could break every wio build
# unnoticed. Each rewritten file must also still parse, and no wio file may
# still call a stripped RGSS probe.

require 'prism'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'fileutils'
require_relative 'strip_wio_rgss_probes'

ROOT = File.expand_path('..', __dir__)
INLINE = File.join(ROOT, 'scripts/strip_wio_inline_helpers.rb')
DEBUG = File.join(ROOT, 'scripts/strip_wio_debug_output.rb')
PROBES = File.join(ROOT, 'scripts/strip_wio_rgss_probes.rb')
CLOCK = File.join(ROOT, 'scripts/strip_wio_clock.rb')
# Mirrors the mrbgem.rake calls: only mruby-rpg2k gets wio_strip_inline_helpers,
# and only mruby-rgss's mrblib/lib.rb gets wio_strip_rgss_probes. A step is a
# script, or [script, the one gem-relative file it applies to].
CHAINS = {
  'mruby-rpg2k' => [INLINE, CLOCK, DEBUG],
  'mruby-lcf' => [CLOCK, DEBUG],
  'mruby-rgss' => [[PROBES, 'mrblib/lib.rb'], CLOCK, DEBUG]
}.freeze

failures = []
files = 0
outputs = []
Dir.mktmpdir do |tmp|
  CHAINS.each do |gem, steps|
    Dir[File.join(ROOT, gem, 'mrblib', '**', '*.rb')].sort.each do |src|
      files += 1
      rel = src.delete_prefix("#{ROOT}/")
      input = src
      steps.each_with_index do |step, i|
        script, only = step
        next if only && rel != "#{gem}/#{only}"

        out = File.join(tmp, "#{i}", rel)
        FileUtils.mkdir_p(File.dirname(out))
        _o, err, status = Open3.capture3(RbConfig.ruby, script, input, out)
        unless status.success?
          failures << "#{rel}: #{File.basename(script)} failed: #{err.lines.grep(/Error|expected/).first&.strip || err.strip}"
          break
        end
        errors = Prism.parse_file(out).errors
        unless errors.empty?
          failures << "#{rel}: #{File.basename(script)} output does not parse: #{errors.first.message}"
          break
        end
        input = out
      end
      outputs << [rel, input]
    end
  end

  outputs.each do |rel, path|
    WioRgssProbes.calls_to(Prism.parse_file(path).value, WioRgssProbes::NAMES).each do |call|
      failures << "#{rel}:#{call.location.start_line}: calls `#{call.name}`, which the wio build strips"
    end
  end
end

# Last in the chain, strip_wio_unreachable_methods.rb (ADR 0218) over the
# rbfiles each wio mrbgem.rake keeps: the analysis must accept the sources
# (no unreviewed computed send) and every strip must apply and parse.
require_relative 'wio_unreachable_methods'
unreachable = 0
missing = []
Dir.mktmpdir do |tmp|
  world = WioUnreachable.checked_in_world(tmp, chain: ->(gem) { CHAINS.fetch(gem) })
  ruby, native = WioUnreachable.outside_srcs(WioUnreachable.checked_in_gem_dirs(missing: missing))
  res = WioUnreachable.analyze(world: world, ruby: ruby, native: native)
  WioUnreachable.check!(res)
  unreachable = res.dead.size
  by_owner = WioUnreachable.by_owner(res.dead)
  world.each do |gem, rbfiles|
    rbfiles.each do |path, rel|
      out = strip_defs_from_source(File.read(path, encoding: 'UTF-8'), by_owner, path,
                                   list_names_by_owner: by_owner, visibility_mids: UNREACHABLE_LIST_MIDS)
      errors = Prism.parse(out).errors
      failures << "#{gem}/#{rel}: unreachable-method strip output does not parse: #{errors.first.message}" unless errors.empty?
    end
  end
rescue RuntimeError => e
  failures << "unreachable-method strip: #{e.message}"
end
# CI's ruby-checks job has no submodules; fewer outside sources only strip more.
warn "note: #{missing.join(', ')} not checked out; their sources were not scanned" unless missing.empty?

failures.each { |f| warn "  FAIL #{f}" }
if failures.empty?
  puts "wio strip scripts check: PASS (#{files} mrblib files, #{unreachable} unreachable defs stripped)"
else
  warn "wio strip scripts check: #{failures.size} failure(s)"
  exit 1
end
