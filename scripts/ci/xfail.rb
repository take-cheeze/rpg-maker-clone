#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs a check that is expected to fail: a failure passes (XFAIL), a pass fails (XPASS), so the
# marker cannot outlive the bug.   ruby scripts/ci/xfail.rb ruby scripts/bc2cpp/x_check.rb
abort 'usage: xfail.rb COMMAND...' if ARGV.empty?

if system(*ARGV)
  warn "XPASS: #{ARGV.join(' ')} passes now; drop the xfail wrapper"
  exit 1
end
warn "XFAIL: #{ARGV.join(' ')} fails as expected"
