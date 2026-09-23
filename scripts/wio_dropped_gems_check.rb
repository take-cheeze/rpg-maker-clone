#!/usr/bin/env ruby
# encoding: UTF-8
# build_config.rb leaves mruby-kernel-ext and mruby-random out of the wio
# cross build (docs/adr/0202), and swaps mruby-math for
# app/wio/mruby-math-wio, which defines only the Math members listed in
# MATH_PROVIDED below (docs/adr/0204). All three trims exist only for a
# game's *own* Ruby (the RGSS script host), and wio ships mruby-rpg2k alone,
# with no compiler/eval to run any. That holds only as long as none of the
# gems wio *does* ship calls a method those gems provide -- and nothing else would notice if
# one started to: there is no wio runtime test in CI, so a new
# `rand`/`Integer()` in mruby-rpg2k would pass every host check and raise
# NoMethodError only on the board.
#
# This is that tripwire. It parses (Ripper.sexp, not a text grep -- `sample`
# or `fail` as a local variable must not count, and neither may a string or
# comment mentioning one) every .rb file under the gems wio links and fails
# on any call to:
#
#   mruby-kernel-ext: Integer() Float() String() Array() Hash() fail caller
#                     __method__ __callee__
#   mruby-random:     rand srand shuffle shuffle! sample, and the Random class
#   mruby-math:       any Math.x / Math::X not in MATH_PROVIDED, and
#                     `include Math`/`extend Math` (bare `sin` after that
#                     could not be checked)
#
# plus a string scan of the same gems' C/C++ sources for mrb_funcall-style
# name lookups of the same methods (the lower-case ones and Random). It scans every file, not just the subset
# wio's mrbgem.rake filters keep, so it errs toward failing.
#
# A hit means one of: drop the call (this engine deliberately avoids rand --
# see build_config.rb's own mruby-random comment), or take the gem back for
# wio in build_config.rb and re-measure (for Math: add the member to
# app/wio/mruby-math-wio/src/math.c and MATH_PROVIDED).

require 'ripper'

ROOT = File.expand_path('..', __dir__)

RUBY_DIRS = %w[
  mruby-rpg2k/mrblib
  mruby-lcf/mrblib
  mruby-rgss/mrblib
  3rd/mruby-stringio/mrblib
].freeze

NATIVE_DIRS = %w[
  mruby-rpg2k/src
  mruby-lcf/src
  mruby-rgss/src
  3rd/mruby-marshal/src
  3rd/mruby-stringio/src
  app/wio/src
  app/wio/hal-wio-io
].freeze

# Kernel methods whose name is a constant: only a call (`Integer(x)`) counts,
# never a plain constant reference (`Integer === x`, `class Integer`).
CONST_CALLS = %w[Integer Float String Array Hash].freeze
METHOD_CALLS = %w[fail caller __method__ __callee__
                  rand srand shuffle shuffle! sample].freeze
CONST_REFS = %w[Random].freeze
# Must match what app/wio/mruby-math-wio/src/math.c defines.
MATH_PROVIDED = %w[PI E DomainError sin].freeze

def contains_math?(node)
  node.is_a?(Array) && (math_const?(node) || node.any? { |c| contains_math?(c) })
end

# `include X` (:command) or `include(X)` (:method_add_arg over :fcall).
def mixin_ident(node)
  tok = case node[0]
        when :command then node[1]
        when :method_add_arg then node[1].is_a?(Array) && node[1][0] == :fcall ? node[1][1] : nil
        end
  tok if tok.is_a?(Array) && tok[0] == :@ident && %w[include extend].include?(tok[1])
end

def math_const?(node)
  node.is_a?(Array) && %i[var_ref top_const_ref].include?(node[0]) &&
    node[1].is_a?(Array) && node[1][0] == :@const && node[1][1] == 'Math'
end

# Walks a Ripper s-expression and yields [name, lineno] for every forbidden
# call/reference.
def each_hit(node, &blk)
  return unless node.is_a?(Array)

  # Math.x(...) / Math::x(...) and Math::X
  if %i[call command_call].include?(node[0]) && math_const?(node[1])
    tok = node.reverse.find { |c| c.is_a?(Array) && %i[@ident @const].include?(c[0]) }
    yield "Math.#{tok[1]}", tok[2][0] if tok && !MATH_PROVIDED.include?(tok[1])
  elsif node[0] == :const_path_ref && math_const?(node[1]) && !MATH_PROVIDED.include?(node[2][1])
    yield "Math::#{node[2][1]}", node[2][2][0]
  elsif (mixin = mixin_ident(node)) && contains_math?(node)
    yield "#{mixin[1]} Math", mixin[2][0]
  end

  case node[0]
  when :vcall, :fcall, :command
    tok = node[1]
    if tok.is_a?(Array) && tok[0] == :@ident && METHOD_CALLS.include?(tok[1])
      yield tok[1], tok[2][0]
    elsif tok.is_a?(Array) && tok[0] == :@const && CONST_CALLS.include?(tok[1]) && node[0] != :vcall
      yield "#{tok[1]}()", tok[2][0]
    end
  when :call, :command_call, :method_add_arg
    # recv.meth / recv.meth(args): the method-name token is the last
    # @ident/@const child of the :call node.
    if node[0] != :method_add_arg
      tok = node.reverse.find { |c| c.is_a?(Array) && %i[@ident @const].include?(c[0]) }
      yield tok[1], tok[2][0] if tok && METHOD_CALLS.include?(tok[1])
    end
  when :var_ref, :top_const_ref, :const_path_ref
    tok = node.last
    yield tok[1], tok[2][0] if tok.is_a?(Array) && tok[0] == :@const && CONST_REFS.include?(tok[1])
  end
  node.each { |c| each_hit(c, &blk) }
end

def hits_in_source(src)
  sexp = Ripper.sexp(src)
  return nil unless sexp

  out = []
  each_hit(sexp) { |name, line| out << [name, line] }
  out
end

failures = []

# Sensitivity: every forbidden form must be caught, and the look-alikes the
# header comment promises to ignore must not be.
positive = <<~RUBY
  a = rand(3)
  srand 1
  x = [1].shuffle
  [1].shuffle!
  y = [1].sample
  z = Integer(a)
  Float("1")
  fail "boom"
  caller
  __method__
  Random.new
  Kernel.rand
  Math.cos(1)
  Math.sqrt 2
  Math::E2
  include Math
  extend(Math)
RUBY
negative = <<~RUBY
  sample = 3
  p sample
  fail_count = 0
  s = "rand() Integer(x)" # rand fail caller
  Integer === s
  class Integer; end
  x = Integer::MAX rescue nil
  @random = 1
  Math.sin(Math::PI) * Math::E
  MyMath.cos(1)
  include Comparable
RUBY
pos = hits_in_source(positive).map(&:first)
expected = ['rand', 'srand', 'shuffle', 'shuffle!', 'sample', 'Integer()', 'Float()', 'fail', 'caller',
            '__method__', 'Random', 'rand', 'Math.cos', 'Math.sqrt', 'Math::E2', 'include Math',
            'extend Math']
unless (expected - pos).empty?
  failures << "self-test: missed #{(expected - pos).inspect} (got #{pos.inspect})"
end
neg = hits_in_source(negative)
failures << "self-test: false positives #{neg.inspect}" unless neg.empty?

scanned = 0
RUBY_DIRS.each do |dir|
  Dir.glob(File.join(ROOT, dir, '**', '*.rb')).sort.each do |path|
    scanned += 1
    rel = path.delete_prefix("#{ROOT}/")
    hits = hits_in_source(File.read(path, encoding: 'UTF-8'))
    if hits.nil?
      failures << "#{rel}: does not parse"
      next
    end
    hits.each { |name, line| failures << "#{rel}:#{line}: calls #{name}" }
  end
end

# CONST_CALLS stay out of the native scan: "Integer"/"String"/... as C
# strings are overwhelmingly class-name lookups (mrb_class_get), not calls to
# Kernel#Integer(), which no C code reaches for.
native_names = (METHOD_CALLS + CONST_REFS + ['Math']).map { |n| Regexp.escape(n) }.join('|')
native_re = /"(?:#{native_names})"|MRB_SYM(?:_B)?\((?:#{native_names.delete('!')})\)/
NATIVE_DIRS.each do |dir|
  Dir.glob(File.join(ROOT, dir, '**', '*.{c,cc,cpp,cxx,h,hxx}')).sort.each do |path|
    scanned += 1
    rel = path.delete_prefix("#{ROOT}/")
    File.read(path, encoding: 'UTF-8').scrub.each_line.with_index(1) do |l, n|
      failures << "#{rel}:#{n}: native lookup #{l.strip}" if l.match?(native_re)
    end
  end
end

if failures.empty?
  puts "wio dropped-gems check: PASS (#{scanned} files: nothing calls into mruby-kernel-ext/" \
       "mruby-random, Math use stays within #{MATH_PROVIDED.join('/')})"
else
  warn 'wio dropped-gems check: FAIL -- a gem wio links uses a method from a gem ' \
       'build_config.rb drops or trims for wio (docs/adr/0202, 0204):'
  failures.each { |f| warn "  #{f}" }
  exit 1
end
