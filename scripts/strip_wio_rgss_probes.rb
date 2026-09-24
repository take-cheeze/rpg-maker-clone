#!/usr/bin/env ruby
# frozen_string_literal: true

# wio-only build step (ADR 0220): deletes the RGSS render/audio probes from a
# build-time copy of mruby-rgss/mrblib/lib.rb. Only src/main.cxx's desktop
# --rgss_effect_probe / --rgss_audio_probe flags call them, and on wio they
# are dead bytecode. build_config.rb's wio_strip_rgss_probes wires this in.
#
# Raises, rather than guessing, when a probe is missing or defined more than
# once, when a def shares a line with other code, when anything left in the
# file still calls a stripped name, or when the output does not parse.
# scripts/wio_strip_scripts_check.rb runs it on every CI build.
#
# Usage: ruby strip_wio_rgss_probes.rb <input.rb> <output.rb>

require 'prism'

module WioRgssProbes
  # `def self.X` methods of `module RGSS`. Each is called only by the others
  # or by src/main.cxx.
  NAMES = %w[
    frame_mean effect_probe transition_shape_probe window_probe
    windowskin_rect_probe tilemap_above_layer_probe probe_wav audio_probe
    wait_for_bgm_pos
  ].freeze

  module_function

  def calls_to(node, names, found = [])
    return found unless node.is_a?(Prism::Node)

    found << node if node.is_a?(Prism::CallNode) && names.include?(node.name.to_s)
    node.compact_child_nodes.each { |c| calls_to(c, names, found) }
    found
  end

  def strip(source, path = '(source)')
    tree = Prism.parse(source)
    raise "#{path}: does not parse: #{tree.errors.first.message}" unless tree.errors.empty?

    rgss = tree.value.statements.body.find do |n|
      n.is_a?(Prism::ModuleNode) && n.constant_path.slice == 'RGSS'
    end
    raise "#{path}: no top-level `module RGSS`" unless rgss

    lines = source.lines
    defs = rgss.body.body.select do |n|
      n.is_a?(Prism::DefNode) && n.receiver.is_a?(Prism::SelfNode) && NAMES.include?(n.name.to_s)
    end
    NAMES.each do |name|
      count = defs.count { |d| d.name.to_s == name }
      raise "#{path}: expected exactly one `def self.#{name}` in module RGSS, found #{count}" unless count == 1
    end

    drop = []
    defs.each do |d|
      first = d.location.start_line - 1
      last = d.location.end_line - 1
      unless lines[first][0...d.location.start_column].strip.empty? &&
             lines[last][d.location.end_column..].strip.empty?
        raise "#{path}: def self.#{d.name} shares a line with other code"
      end

      drop.concat((first..last).to_a)
    end
    out = lines.each_with_index.reject { |_, i| drop.include?(i) }.map(&:first).join

    check = Prism.parse(out)
    raise "#{path}: output does not parse: #{check.errors.first.message}" unless check.errors.empty?

    left = calls_to(check.value, NAMES)
    unless left.empty?
      raise "#{path}:#{left.first.location.start_line}: still calls stripped probe " \
            "`#{left.first.name}`"
    end
    out
  end
end

if __FILE__ == $PROGRAM_NAME
  in_path, out_path = ARGV
  raise ArgumentError, "usage: #{$PROGRAM_NAME} <input.rb> <output.rb>" unless in_path && out_path

  File.write(out_path, WioRgssProbes.strip(File.read(in_path), in_path))
end
