#!/usr/bin/env ruby
# frozen_string_literal: true

# Check UNPASSED_OPTIONAL_PROOF (CodeGen#constructor_unpassed_optionals, nil_pruned_definition_class): an optional
# initialize parameter that no `new`/`super` site passes always holds its default, so `@x = param || Klass.new(...)`
# stores a Klass (or nil) and ClassLayout proves the ivar's class. Positive: no caller passes it. Negatives: one caller
# passes it, a splat `new`, a keyword call into an initialize without keyword parameters (its keywords arrive as one
# more positional), and a fallback arm that is itself two classes.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/unpassed_optional_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~RUBY
  class UpHelper
    def initialize(db); @db = db; end
    def compute(x); x + 1; end
  end
  class UpOther
    def compute(x); x + 2; end
  end

  class UpHold
    def initialize(db, roster = nil)
      @db = db
      @roster = roster || UpHelper.new(db)
    end
    def run; @roster.compute(3); end
  end

  class UpPassed
    def initialize(db, roster = nil); @roster = roster || UpHelper.new(db); end
    def run; @roster.compute(3); end
  end

  class UpSplat
    def initialize(db, roster = nil); @roster = roster || UpHelper.new(db); end
    def run; @roster.compute(3); end
  end

  class UpKw
    def initialize(db, roster = nil); @roster = roster || UpHelper.new(db); end
    def run; @roster.compute(3); end
  end

  class UpMixed
    def initialize(db, flag, roster = nil); @roster = roster || (flag ? UpHelper.new(db) : UpOther.new); end
    def run; @roster.compute(3); end
  end

  UpHold.new(1).run
  UpPassed.new(1).run
  UpPassed.new(1, UpOther.new).run
  up_args = [1]
  UpSplat.new(*up_args).run
  UpKw.new(1, k: 2).run
  UpMixed.new(1, true).run
RUBY
OWNERS = %w[UpHelper UpOther UpHold UpPassed UpSplat UpKw UpMixed].freeze

abort 'unpassed_optional_check: set MRBC' unless ENV['MRBC']
ENV['BC2CPP_STRICT_HINTS_UNREVIEWED'] = 'allow'
Dir.mktmpdir do |dir|
  _code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, closed: true, only_owners: OWNERS)
  unpassed = err.lines.grep(/\A  UNPASSED /).map(&:strip)
  hints = err.lines.grep(/\A  CLASS_HINT /).map { |l| l.split.drop(1).join(' ') }

  puts '== the parameter no caller passes'
  check.call('UpHold#initialize: register 2 is never passed', unpassed.include?('UNPASSED UpHold#initialize registers 2'))
  check.call('UpHold#@roster is proven UpHelper', hints.include?('UpHold#@roster (UpHelper)'))

  puts '== withdrawals'
  check.call('a caller passing it leaves UpPassed unproven', unpassed.none? { |l| l.include?('UpPassed#') } &&
                                                             hints.none? { |h| h.start_with?('UpPassed#@roster') })
  check.call('a splat new leaves UpSplat unproven', unpassed.none? { |l| l.include?('UpSplat#') } &&
                                                    hints.none? { |h| h.start_with?('UpSplat#@roster') })
  check.call('keywords counted as a positional leave UpKw unproven', unpassed.none? { |l| l.include?('UpKw#') } &&
                                                                       hints.none? { |h| h.start_with?('UpKw#@roster') })
  check.call('UpMixed: the parameter is unpassed', unpassed.include?('UNPASSED UpMixed#initialize registers 3'))
  check.call('UpMixed: a two-class fallback stays unproven', hints.none? { |h| h.start_with?('UpMixed#@roster') })
end

if failures.empty?
  puts 'unpassed_optional_check: all ok'
else
  abort "unpassed_optional_check: FAILED: #{failures.join(', ')}"
end
