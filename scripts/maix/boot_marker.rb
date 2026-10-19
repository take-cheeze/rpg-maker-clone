#!/usr/bin/env ruby
# frozen_string_literal: true

# Matches a bring-up marker (e.g. "REACHED loop()") in the console output that
# scripts/maix/renode_boot.bash captures for maix-smoke. Renode writes its own
# log lines ("HH:MM:SS.mmm [WARNING] ...") to the same stream, and one can land
# in the middle of a marker. Such a line is removed before the substring match,
# and nothing else is, so a log without the marker still fails.
#
# Usage: ruby scripts/maix/boot_marker.rb FILE|- MARKER
# Exits 0 when the marker is found, 1 when it is not.

module MaixBootMarker
  # A whole Renode log record (timestamp, level, message up to end of line).
  RENODE_LOG_RECORD = /\d{2}:\d{2}:\d{2}(?:\.\d+)? \[(?:WARNING|INFO|ERROR|DEBUG)\][^\n]*\n?/

  module_function

  def found?(output, marker)
    return true if output.include?(marker)

    output.gsub(RENODE_LOG_RECORD, '').include?(marker)
  end
end

if $PROGRAM_NAME == __FILE__
  unless ARGV.size == 2
    warn 'usage: ruby scripts/maix/boot_marker.rb FILE|- MARKER'
    exit 2
  end
  source, marker = ARGV
  output = source == '-' ? $stdin.read : File.read(source)
  if MaixBootMarker.found?(output, marker)
    exit 0
  end
  warn "boot marker not found: #{marker.inspect}"
  exit 1
end
