#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails when the dispatch analysis would fall back to the receiver-blind cascade for the closed world's own
# program (core Ruby included). The fallback applies once an instantiating send with an unknown or instance
# receiver may create an engine instance at load time; then every engine method is reachable by name and the
# unregistration lists shrink to almost nothing. A strict run raises instead, so the fallback is visible in the gate.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/engine_live_check.rb [--core-gems=a,b,c]
#   default --core-gems: the closed world's canonical core gems (BC2CPP_CANONICAL_CORE_GEMS).

require 'shellwords'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

repo_root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
core_arg = ARGV.find { |a| a.start_with?('--core-gems=') }
core_gems = core_arg ? core_arg.delete_prefix('--core-gems=').split(',').map(&:strip).reject(&:empty?) : BC2CPP_CANONICAL_CORE_GEMS

begin
  StaticDispatchRegistrations.analyze(repo_root, mrbc, closed_only: true, core_gems: core_gems, strict: true)
rescue StaticDispatchRegistrations::EngineLiveError => e
  warn "engine_live_check: #{e.message}"
  exit 1
end
puts 'engine_live_check: no receiver-blind fallback for the closed world'
