#!/usr/bin/env ruby
# frozen_string_literal: true

# wio-only build step (ADR 0221): the wio build links no mruby-time, because
# the board has no set real-time clock. Its Time.now was 1970 plus uptime.
# This rewrites the two engine uses of Time in a build-time copy of
# mruby-rpg2k's mrblib:
#
# - The F8 bug-report file name is stamped with Graphics.frame_count. That
#   is unique per press within a session, as the uptime-based clock was.
# - State.ole_now returns NO_CLOCK_TIMESTAMP, the date lsd_io.rb already
#   falls back to without a clock. game/lsd_io.rb is not in wio's rbfiles
#   today; it is rewritten anyway, so it is clock-free if it comes back.
#
# It then refuses any output that still names Time. Running over every wio
# mrblib file makes that a build-time guarantee, not a convention.
# build_config.rb's wio_strip_clock runs it after wio_strip_inline_helpers,
# which inlines #bug_report_stamp into its caller, so the main.rb pattern is
# that inlined form. scripts/wio_strip_scripts_check.rb runs it in CI.
#
# Usage: ruby strip_wio_clock.rb <input.rb> <output.rb>

require 'prism'

module WioClock
  REWRITES = {
    'mrblib/main.rb' => [
      ['"#{GAME_DIR}/bugreport_#{(t = Time.now; "%04d%02d%02d_%02d%02d%02d" % ' \
       '[t.year, t.month, t.day, t.hour, t.min, t.sec])}.md"',
       '"#{GAME_DIR}/bugreport_frame#{"%08d" % Graphics.frame_count}.md"']
    ],
    'mrblib/game/lsd_io.rb' => [
      ["    def self.ole_now\n      Time.now.to_i / 86400.0 + OLE_EPOCH_OFFSET\n" \
       "    rescue StandardError\n      NO_CLOCK_TIMESTAMP\n    end\n",
       "    def self.ole_now\n      NO_CLOCK_TIMESTAMP\n    end\n"]
    ]
  }.freeze

  module_function

  def time_refs(node, found = [])
    return found unless node.is_a?(Prism::Node)

    found << node if node.is_a?(Prism::ConstantReadNode) && node.name == :Time
    found << node if node.is_a?(Prism::ConstantPathNode) && node.slice.split('::').last == 'Time'
    node.compact_child_nodes.each { |c| time_refs(c, found) }
    found
  end

  def rewrite(source, path)
    key = REWRITES.keys.find { |k| path.end_with?("/#{k}") }
    out = source
    (key ? REWRITES[key] : []).each do |old, new|
      count = out.scan(old).length
      raise "#{path}: expected exactly 1 occurrence of #{old.inspect}, found #{count} -- " \
            'the source has drifted; update strip_wio_clock.rb' unless count == 1

      out = out.sub(old) { new }
    end

    tree = Prism.parse(out)
    raise "#{path}: output does not parse: #{tree.errors.first.message}" unless tree.errors.empty?

    left = time_refs(tree.value)
    unless left.empty?
      raise "#{path}:#{left.first.location.start_line}: still names Time, which the wio " \
            'build does not link (ADR 0221)'
    end
    out
  end
end

if __FILE__ == $PROGRAM_NAME
  in_path, out_path = ARGV
  raise ArgumentError, "usage: #{$PROGRAM_NAME} <input.rb> <output.rb>" unless in_path && out_path

  File.write(out_path, WioClock.rewrite(File.read(in_path, encoding: 'UTF-8'), in_path))
end
