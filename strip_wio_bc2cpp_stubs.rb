#!/usr/bin/env ruby
# frozen_string_literal: true

# wio-only build step: strips the interpreted-bytecode BODY of every method
# a *-compiled gem's own bc2cpp.rb run actually registers a real C++
# override for, out of a build-time copy of the *base* gem's own mrblib
# source (never the checked-in source -- see build_config.rb's
# wio_strip_bc2cpp_stubs for how this hooks into a gem's own mrbgem.rake).
# See docs/adr/0144 for the full design writeup and its measured result.
#
# Why this exists: bc2cpp.rb's C++ override (installed at the *-compiled
# gem's own gem_init, via mrb_define_method) always wins once installed --
# but it never removes the ORIGINAL interpreted-bytecode body from the
# base gem's own mrblib blob, so a wio build with RPGMAKER_BC2CPP=1
# currently pays for both the C++ override AND the original bytecode of
# every method it covers, permanently (docs/adr/0142/0143): mruby loads
# each gem's entire mrblib as one monolithic byte array via a single
# mrb_load_irep_buf call, so individual methods are not separable linker
# sections a plain --gc-sections dead-strip could ever remove.
#
# Deletes the whole `def ... end` outright -- header line included -- and
# relies on Ruby's own default `method_missing` (raising a real
# `NoMethodError` for any call to an undefined method, no custom handler
# needed) to cover the gap, rather than installing an explicit
# `raise NotImplementedError` stub body. An earlier version of this script
# kept the `def` and only replaced its body, specifically to keep
# `respond_to?`/`method(:x)` answering the same way before and after
# stripping -- but that concern is already subsumed by the one
# correctness check this mechanism requires before stripping ANY owner in
# the first place (see docs/adr/0144's own "the one real correctness
# question this round checked" section): whether real code could observe
# the method missing at all in the narrow window between the base gem's
# own mrblib load (which is what this script's own output feeds) and the
# `*-compiled` gem's own gem_init installing the real C++ override a few
# lines of load order later. If nothing can *call* the method in that
# window (the thing this mechanism already has to verify per owner), then
# nothing can `respond_to?`/`method(:x)` it either -- a stub body earns
# its keep only for a window this mechanism has independently ruled out
# already. And a real `mrbc` measurement (docs/adr/0144) found the
# `raise NotImplementedError` stub is not even free: `NotImplementedError`
# is its own new GETCONST + symbol-table reference, `raise` its own SSEND,
# on every single stripped method, which can cost more than the trivial
# accessor body it replaces -- deleting the `def` entirely has none of
# that: no TDEF/DEF opcode, no body opcodes, no new symbol references,
# nothing. Once the C++ override installs, `respond_to?`/`.arity`/
# `method(:x)` all answer from *that* override's own real signature
# regardless of whether the original Ruby source ever defined the method
# at all -- there is no "preserve the original arity" property to
# maintain here. NEVER touches a method this build does not have a
# *confirmed, real* C++ override for: the method list comes from
# wio_registered_methods.rb's own real bc2cpp.rb stderr capture (its
# first argument here is that script's own TSV output), never
# independently re-derived or hand-guessed in this file.
#
# AST-based (RubyVM::AbstractSyntaxTree), not regex/text-based, for
# finding each stripped method's real line/column span -- see
# docs/adr/0129/0131's own documented regex-based failure modes (wrong
# line numbers, a `:symbol` literal confused for a real call, multi-line
# call corruption) for why that approach was already tried and rejected
# once in this codebase. Unlike strip_wio_inline_helpers.rb's own
# hand-curated, line-text-matched REWRITES table (a small, one-off,
# manually-verified set of substitutions authored offline against a
# fixed source snapshot), this script's input -- which methods on which
# owner to strip -- changes every time bc2cpp.rb's own real coverage
# changes, so the location-finding itself has to run for real at build
# time rather than being authored once by hand; plain `ripper` tokens
# (as strip_wio_debug_output.rb uses) cannot give real per-node
# line/COLUMN spans without re-deriving expression boundaries by hand, so
# this uses RubyVM::AbstractSyntaxTree instead, whose DEFN/CLASS/MODULE
# nodes carry exact (first_lineno, first_column)..(last_lineno,
# last_column) spans directly, with real node-type checks (CLASS/MODULE
# nesting, DEFN) rather than any text search.
#
# Current, deliberate limitations -- both fail loudly (raising, never
# silently skipping or guessing), so a future round that hits either has
# to look at it rather than silently ship an unsound deletion:
#   - Only plain instance-method owners (a `class`/`module` nesting path,
#     e.g. "RGSS::Sprite") are supported. A ".singleton" owner (a real
#     `def self.foo` or `class << self; def foo; end; end` method --
#     bc2cpp.rb's own SDEF/SCLASS pseudo-owner) is never even collected
#     as a candidate (see load_registered below) -- DEFS/SCLASS
#     span-finding needs its own, separately verified support, out of
#     scope for this round's bounded proof.
#   - A `def name(args)` whose own signature does not fit on one physical
#     source line, or a one-line `def name; body; end` (first_lineno ==
#     last_lineno), is left completely untouched (raises) rather than
#     guessed at. Every real target this round's bounded proof strips
#     (RGSS::Sprite, all 17 real methods) is a plain multi-line `def
#     name\n ... \nend` with a single-line signature, so this gap has
#     never actually been hit -- flagged here for whichever future round
#     first tries to strip a method that needs it.
#
# Usage: ruby strip_wio_bc2cpp_stubs.rb <registered.tsv> <owners-csv> <input.rb> <output.rb>

require 'set'

# Reads wio_registered_methods.rb's own TSV output and returns
# { "Owner::Path" => Set["method_name", ...] } for exactly the owners this
# invocation was asked to strip (owners-csv) -- every other real owner in
# the TSV (there will be many: the TSV covers a whole *-compiled gem, this
# script's own caller only ever asks for a bounded subset) is silently
# ignored, and any ".singleton" owner is never collected at all regardless
# of whether it was asked for (see the file comment above).
def load_registered(tsv_path, owners)
  wanted = owners.to_set
  by_owner = Hash.new { |h, k| h[k] = Set.new }
  File.foreach(tsv_path) do |line|
    owner, name, _arity, _visibility, singleton = line.chomp.split("\t")
    next unless owner && wanted.include?(owner)
    next if singleton == '1'

    by_owner[owner] << name
  end
  by_owner
end

# The real class/module nesting path a CLASS/MODULE node's own name node
# denotes ("RGSS::Sprite" for `module RGSS; class Sprite`, one COLON2 per
# nesting level with the outer name as its own base child) -- nil for any
# name-node shape this script doesn't recognize (there are none in this
# codebase's own class/module reopenings today; a nil here just means the
# CLASS/MODULE contributes no path segment, rather than guessing wrong).
def const_path_of(node)
  return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

  case node.type
  when :COLON2
    base, name = node.children
    base_path = const_path_of(base)
    base_path ? "#{base_path}::#{name}" : name.to_s
  when :COLON3
    node.children[0].to_s
  end
end

# Walks the real AST, tracking the current class/module nesting path, and
# appends { owner:, name:, node: } for every real DEFN (instance method
# def) node found -- `stack` is the list of enclosing CLASS/MODULE names,
# joined with "::" to become `owner`. SCLASS (`class << self`) bodies and
# DEFS (`def self.foo`) nodes are deliberately never descended into/
# recorded (singleton methods are out of scope -- see the file comment).
def collect_defs(node, stack, out)
  return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

  case node.type
  when :CLASS
    name = const_path_of(node.children[0])
    collect_defs(node.children[2], name ? stack + [name] : stack, out)
    return
  when :MODULE
    name = const_path_of(node.children[0])
    collect_defs(node.children[1], name ? stack + [name] : stack, out)
    return
  when :SCLASS
    return
  when :DEFS
    return
  when :DEFN
    out << { owner: stack.join('::'), name: node.children[0].to_s, node: node } unless stack.empty?
    return
  end

  node.children.each { |c| collect_defs(c, stack, out) if c.is_a?(RubyVM::AbstractSyntaxTree::Node) }
end

def parses?(source)
  RubyVM::AbstractSyntaxTree.parse(source)
  true
rescue SyntaxError
  false
end

# Builds the { header_line0 => last_line0 } deletion plan for every real
# DEFN this script was asked to (and safely can) strip, and applies it to
# `lines` (0-based array, one element per physical source line including
# its own trailing newline) in a single top-to-bottom pass -- every line
# from a stripped method's own header through its own `end` is dropped
# entirely, no replacement text inserted at all (see the file comment for
# why a stub body is unnecessary here).
def apply_deletion_plan(lines, wanted_defs, path)
  plan = {}
  wanted_defs.each do |d|
    node = d[:node]
    first0 = node.first_lineno - 1
    last0 = node.last_lineno - 1

    raise "#{path}: #{d[:owner]}##{d[:name]}: one-line `def ...; end` is not supported by " \
          'strip_wio_bc2cpp_stubs.rb (see its own file comment) -- refusing to guess' if first0 == last0

    header = lines[first0]
    raise "#{path}: #{d[:owner]}##{d[:name]}: no source line at #{first0 + 1}" unless header

    raise "#{path}: #{d[:owner]}##{d[:name]}: def signature does not fit on one line " \
          '(unbalanced parens on its own header line) -- not supported, refusing to guess' \
      if header.count('(') != header.count(')')

    raise "#{path}: #{d[:owner]}##{d[:name]}: two stripped methods claim the same header line " \
          '-- source has drifted since this owner list was captured' if plan.key?(first0)

    plan[first0] = last0
  end

  out = []
  i = 0
  while i < lines.length
    if plan.key?(i)
      i = plan[i] + 1
    else
      out << lines[i]
      i += 1
    end
  end
  out.join
end

if __FILE__ == $PROGRAM_NAME
  registered_tsv, owners_csv, in_path, out_path = ARGV
  unless registered_tsv && owners_csv && in_path && out_path
    raise ArgumentError, "usage: #{$PROGRAM_NAME} <registered.tsv> <owners-csv> <input.rb> <output.rb>"
  end

  owners = owners_csv.split(',')
  by_owner = load_registered(registered_tsv, owners)
  source = File.read(in_path, external_encoding: Encoding::UTF_8)

  raise "strip_wio_bc2cpp_stubs: #{in_path} does not parse to begin with" unless parses?(source)

  if by_owner.values.all?(&:empty?)
    # None of this invocation's target owners have any real registered
    # method at all (the common case -- most rbfiles define none of
    # today's bounded proof owners): copy through byte-for-byte rather
    # than pay for a parse this file never needed.
    File.write(out_path, source)
  else
    ast = RubyVM::AbstractSyntaxTree.parse(source)
    defs = []
    collect_defs(ast, [], defs)
    wanted = defs.select { |d| by_owner[d[:owner]].include?(d[:name]) }

    if wanted.empty?
      File.write(out_path, source)
    else
      rewritten = apply_deletion_plan(source.each_line.to_a, wanted, in_path)
      raise "strip_wio_bc2cpp_stubs: rewrite of #{in_path} does not parse; leaving the original " \
            'untouched' unless parses?(rewritten)

      File.write(out_path, rewritten)
    end
  end
end
