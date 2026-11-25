#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs every WIO_WORLD_STRIP pass (scripts/wio/world_strip.rb), in its chain order, over every engine mrblib file,
# whether or not the build enables it: each script raises when a pattern no longer matches its source, and only a wio
# build runs them otherwise. Each rewritten file must also still parse, and no file may still call a stripped RGSS
# probe.

require 'prism'
require 'set'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'fileutils'
require_relative 'strip_rgss_probes'
require_relative 'world_strip'

ROOT = WioWorldStrip::ROOT
GEMS = WioWorldStrip::PASSES.values.flat_map { |_, gems, _| gems }.uniq

failures = []
files = 0
outputs = []
Dir.mktmpdir do |tmp|
  GEMS.each do |gem|
    Dir[File.join(ROOT, gem, 'mrblib', '**', '*.rb')].sort.each do |src|
      files += 1
      rel = src.delete_prefix("#{ROOT}/")
      input = src
      WioWorldStrip.steps(rel, WioWorldStrip::PASSES.keys).each_with_index do |script, i|
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

# INLINE_AUDIT: strip_inline_helpers.rb copies each deleted method's body into its call site by hand, so check what
# a copy can get wrong: a parameter of the deleted method left unbound in the copy, and a deleted method something
# still names as a Symbol (&:name, send, respond_to?), which no call-site rewrite reaches.
load File.join(__dir__, 'strip_inline_helpers.rb')
def bare_names(node, acc = Set.new)
  return acc unless node.is_a?(Prism::Node)

  acc << node.name.to_s if node.is_a?(Prism::LocalVariableReadNode) ||
                           (node.is_a?(Prism::CallNode) && node.receiver.nil? && node.variable_call?)
  node.compact_child_nodes.each { |c| bare_names(c, acc) }
  acc
end
deleted = {}
REWRITES.each do |rel, rw|
  lines = File.readlines(File.join(ROOT, rel))
  rw[:deletions].each do |d|
    start = lines.index { |l| l.chomp == d[:first] }
    m = lines[start, d[:expect_lines]].join.match(/def (?:self\.)?([\w?!=]+)(?:\(([^)]*)\))?/)
    deleted[m[1]] = (m[2] || '').split(',').map { |p| p.strip.sub(/\A[*&]+/, '').sub(/\s*[=:].*\z/m, '') }
  end
end
called = ->(name, text) { text.match?(/(?<![\w@.:])#{Regexp.escape(name)}(?![\w?!])/) }
REWRITES.each do |rel, rw|
  (rw[:substitutions] || []).each do |sub|
    callee = deleted.keys.find { |n| called.call(n, sub[:old]) } or next
    names = bare_names(Prism.parse(sub[:new]).value)
    deleted[callee].each do |param|
      next unless names.include?(param) && !called.call(param, sub[:old])

      failures << "#{rel}: the inlined #{callee} still names its parameter `#{param}`: #{sub[:old].strip}"
    end
  end
end
GEMS.each do |gem|
  Dir[File.join(ROOT, gem, 'mrblib*', '**', '*.rb')].sort.each do |path|
    File.foreach(path).with_index(1) do |line, no|
      next if line.lstrip.start_with?('#')

      deleted.each_key do |name|
        next unless line.match?(/:#{Regexp.escape(name)}(?![\w?!])/)

        failures << "#{path.delete_prefix("#{ROOT}/")}:#{no}: names #{name}, which strip_inline_helpers.rb deletes"
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
