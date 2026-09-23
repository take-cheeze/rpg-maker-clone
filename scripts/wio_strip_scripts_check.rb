#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs the wio-only mrblib rewrites (strip_wio_inline_helpers.rb, then
# strip_wio_debug_output.rb) over every mrblib file, chained in the order
# build_config.rb's wio_strip_* filters apply them. Each script raises when a
# pattern no longer matches its source, but only a MRUBY_TARGET=wio build ran
# them, and no CI job builds wio, so a source edit could break every wio build
# unnoticed. Each rewritten file must also still parse.

require 'prism'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
INLINE = File.join(ROOT, 'scripts/strip_wio_inline_helpers.rb')
DEBUG = File.join(ROOT, 'scripts/strip_wio_debug_output.rb')
# Mirrors the mrbgem.rake calls: only mruby-rpg2k gets wio_strip_inline_helpers.
CHAINS = {
  'mruby-rpg2k' => [INLINE, DEBUG],
  'mruby-lcf' => [DEBUG],
  'mruby-rgss' => [DEBUG]
}.freeze

failures = []
files = 0
Dir.mktmpdir do |tmp|
  CHAINS.each do |gem, scripts|
    Dir[File.join(ROOT, gem, 'mrblib', '**', '*.rb')].sort.each do |src|
      files += 1
      rel = src.delete_prefix("#{ROOT}/")
      input = src
      scripts.each_with_index do |script, i|
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
