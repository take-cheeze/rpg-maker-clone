#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs the wio-only mrblib rewrites (strip_wio_rgss_probes.rb,
# strip_wio_inline_helpers.rb, then strip_wio_debug_output.rb) over every
# mrblib file, chained in the order build_config.rb's wio_strip_* filters
# apply them. Each script raises when a pattern no longer matches its source,
# but only a MRUBY_TARGET=wio build ran them, and no CI job builds wio, so a
# source edit could break every wio build unnoticed. Each rewritten file must
# also still parse, and no wio file may still call a stripped RGSS probe.

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
# Mirrors the mrbgem.rake calls: only mruby-rpg2k gets wio_strip_inline_helpers,
# and only mruby-rgss's mrblib/lib.rb gets wio_strip_rgss_probes. A step is a
# script, or [script, the one gem-relative file it applies to].
CHAINS = {
  'mruby-rpg2k' => [INLINE, DEBUG],
  'mruby-lcf' => [DEBUG],
  'mruby-rgss' => [[PROBES, 'mrblib/lib.rb'], DEBUG]
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

failures.each { |f| warn "  FAIL #{f}" }
if failures.empty?
  puts "wio strip scripts check: PASS (#{files} mrblib files)"
else
  warn "wio strip scripts check: #{failures.size} failure(s)"
  exit 1
end
