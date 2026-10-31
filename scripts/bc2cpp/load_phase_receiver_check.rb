#!/usr/bin/env ruby
# frozen_string_literal: true

# LOAD_PHASE_RECEIVER (docs/bc2cpp-load-phase-receiver.md): the stub rule (MrblibStubs.stubbable) keeps a compiled body
# that load-time code may run, and StaticDispatchRegistrations.load_phase decides that BY NAME: a load-time send of
# `each` keeps every `each` body, whatever its receiver. The receiver-aware rule keeps a body only for the receiver
# classes a send can reach: an `each` sent on a constant whose value is an Array keeps Array#each and nothing else.
#
# This fixture asserts the receiver-aware answer, so it FAILS today by design (the name-based rule keeps Range#each):
#
#   W1  EXTS = [...].freeze; EXTS.each at load. Range#each is stubbable under the receiver-aware rule; Array#each is kept
#       (it runs at load). Today Range#each is kept with reason "runs at load". FAILS until the rule is implemented.
#   W2  RANGE = (0..2); RANGE.each at load. Range#each runs at load, so it is kept under either rule (a control).
#   W3  a parameter's receiver, `seq.each`, where seq is passed a Range at load. Its class is unknown, so the name-based
#       answer is kept (the unknown receiver keeps every `each`, a control).
#
# Each world is compiled by the host mrbc (MRBC) and judged by MrblibStubs.stubbable with BC2CPP_STUB_LOG set, so the
# reason of every kept body is read from the same log the build writes. Needs MRBC (a host mrbc); SKIPs without it.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/load_phase_receiver_check.rb

require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ENV['BC2CPP_SIG_DIRS'] = ''
suite = FixtureCheck.new('load_phase_receiver_check')
suite.require_mrbc!

# Core-owned methods, as the closed world has them: a reopened Range and Array, with plain loops inside.
CORE_EACH = <<~'RUBY'
  class Range
    def each
      i = self.begin
      last = self.end
      while i <= last
        yield i
        i += 1
      end
      self
    end
  end

  class Array
    def each
      i = 0
      while i < size
        yield self[i]
        i += 1
      end
      self
    end
  end
RUBY

W1 = <<~'RUBY'
  module Fixture
    EXTS = ['', '.ogg', '.wav'].freeze
    EXTS.each { |e| e }
  end
RUBY

W2 = <<~'RUBY'
  module Fixture
    RANGE = (0..2)
    RANGE.each { |v| v }
  end
RUBY

W3 = <<~'RUBY'
  module Fixture
    def self.visit(seq)
      seq.each { |v| v }
    end
    visit(0..2)
  end
RUBY

# The bodies judged: every each of the two core classes, which is what the name-based rule can keep.
COMPILED = [
  { owner: 'Range', name: 'each' }, { owner: 'Array', name: 'each' }
].freeze

def describe(decision)
  decision == true ? 'stubbable' : "kept, reason \"#{decision}\""
end

# The stub decision of every key of COMPILED for one world: { key => true (stubbable) | reason string (kept) }.
def decisions(suite, source)
  suite.compile(CORE_EACH + source) do |ireps, root, _dir|
    Dir.mktmpdir('load_phase_receiver_log') do |dir|
      log = File.join(dir, 'stub.log')
      registry = build_registry(ireps, root)[0]
      stubbed = nil
      begin
        ENV['BC2CPP_STUB_LOG'] = log
        stubbed = MrblibStubs.stubbable(COMPILED, ireps, registry)
      ensure
        ENV.delete('BC2CPP_STUB_LOG')
      end
      reasons = File.file?(log) ? File.readlines(log, chomp: true).to_h { |line| line.split("\t", 2).reverse } : {}
      COMPILED.to_h do |m|
        key = "#{m[:owner]}##{m[:name]}"
        [key, stubbed.include?(key) ? true : reasons.fetch(key, 'not judged')]
      end
    end
  end
end

w1 = decisions(suite, W1)
puts '  W1: a constant Array receiver at load (EXTS.each)'
suite.check('Array#each is kept: it runs at load', w1['Array#each'] != true)
suite.check("Range#each is stubbable: no load-time send reaches it (now: #{describe(w1['Range#each'])})",
            w1['Range#each'] == true)

w2 = decisions(suite, W2)
puts '  W2: a constant Range receiver at load (RANGE.each), a control'
suite.check("Range#each is kept: RANGE is a Range (now: #{describe(w2['Range#each'])})",
            w2['Range#each'] != true)

w3 = decisions(suite, W3)
puts '  W3: a parameter receiver at load (seq.each), a control'
suite.check("Range#each is kept: the receiver's class is unknown (now: #{describe(w3['Range#each'])})",
            w3['Range#each'] != true)

suite.finish!
