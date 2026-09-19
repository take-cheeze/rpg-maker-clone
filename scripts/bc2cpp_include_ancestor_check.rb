#!/usr/bin/env ruby
# encoding: UTF-8
# Prove the ANCESTOR_MIXINS_SUPPORT whole-world `include`/`prepend` scan
# (tools/bc2cpp/bc2cpp.rb's build_registry) and the `super`-soundness guard
# it feeds (CodeGen#super_reaches_superclass?) both read a real closed world
# correctly -- the fact SUPER_SUPPORT used to assert by hand per SUPER_TARGETS
# entry (docs/adr: no `include`d module sits between a class and its declared
# superclass, so a `super` really lands on the superclass).
#
# This is a *static* check on a purpose-built synthetic closed world (not the
# real gems), so every expected outcome is known by construction -- it drives
# the real mrbc + the real build_registry + the real CodeGen guard rather than
# reimplementing any of them. The real-project golden coverage check
# (scripts/bc2cpp_coverage_check.bash) proves the same guard never wrongly
# declines a shipped `super`; this proves it also never WRONGLY ACCEPTS one a
# module would intercept, and that the scan recognizes every include/prepend
# shape (self-implicit, transitive, prepend, and an unresolvable explicit
# receiver flagged as unknown).
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp_include_ancestor_check.rb

require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
require_relative '../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Mfoo
    def foo; :modfoo; end
  end
  module Mbar
    def bar; :mbar; end
  end
  module Mtrans_b
    def foo; :via_b; end
  end
  module Mtrans_a
    include Mtrans_b
  end
  class Base
    def foo; :base; end
  end
  class Intervening < Base
    include Mfoo
    def foo; super; end
  end
  class Safe < Base
    include Mbar
    def foo; super; end
  end
  class Transitive < Base
    include Mtrans_a
    def foo; super; end
  end
  class Prepended < Base
    prepend Mfoo
    def foo; super; end
  end
  class PlainSuper < Base
    def foo; super; end
  end
  class UnknownMixin < Base
    String.include Mfoo
    def foo; super; end
  end
RUBY

failures = []
check = lambda do |what, actual, expected|
  if actual == expected
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}: expected #{expected.inspect}, got #{actual.inspect}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  src = File.join(dir, 'synthetic.rb')
  File.write(src, SRC)

  symbol = 'bc2cpp_include_ancestor_check'
  c_src, disasm_text = run_mrbc(src, symbol, dir)
  ireps, root_label = parse_c_dump(c_src, symbol)
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm_text)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry, superclass_of, _container_constants, included_modules, prepended_modules, unknown_mixins =
    build_registry(ireps, root_label)

  # -- build_registry's own whole-world mixin scan (presence/shape only) --
  check.call('Intervening records an include', included_modules['Intervening'].is_a?(Array), true)
  check.call('Safe records an include', included_modules['Safe'].is_a?(Array), true)
  check.call('Transitive records an include', included_modules['Transitive'].is_a?(Array), true)
  check.call('Mtrans_a itself records an include', included_modules['Mtrans_a'].is_a?(Array), true)
  check.call('Prepended records a prepend', prepended_modules['Prepended'].is_a?(Array), true)
  check.call('Prepended records no plain include', included_modules['Prepended'], nil)
  check.call('PlainSuper records no include', included_modules['PlainSuper'], nil)
  check.call('UnknownMixin (explicit-receiver include) is flagged unknown',
             unknown_mixins.include?('UnknownMixin'), true)
  check.call('Intervening is NOT flagged unknown', unknown_mixins.include?('Intervening'), false)

  # -- CodeGen's own re-derived super-soundness guard (conservative: any plain
  #    include -> decline; prepend-only / no-include -> reach; unknown -> decline) --
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                    included_modules, prepended_modules, unknown_mixins, analysis_only: true)
  reaches = lambda do |owner|
    def_ = registry['foo'].find { |d| d.owner == owner }
    raise "no foo def for #{owner}" unless def_

    gen.super_reaches_superclass?(def_)
  end
  check.call('Intervening: has an include -> decline', reaches.call('Intervening'), false)
  check.call('Safe: has an include -> decline (conservative)', reaches.call('Safe'), false)
  check.call('Transitive: has an include -> decline', reaches.call('Transitive'), false)
  check.call('Prepended: prepend never intervenes -> reaches Base', reaches.call('Prepended'), true)
  check.call('PlainSuper: no includes -> reaches Base', reaches.call('PlainSuper'), true)
  check.call('UnknownMixin: unresolvable include -> decline', reaches.call('UnknownMixin'), false)
end

if failures.empty?
  puts 'bc2cpp include/prepend ancestor scan check: PASS'
else
  warn "bc2cpp include/prepend ancestor scan check: #{failures.size} failure(s)"
  exit 1
end
