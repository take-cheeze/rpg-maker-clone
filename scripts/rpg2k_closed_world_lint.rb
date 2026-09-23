#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8
#
# RuboCop-style lint for the Ruby that bc2cpp compiles as a closed world
# (mruby-rpg2k, mruby-lcf, mruby-rgss mrblib). Each cop flags a construct that
# lets a call reach a method the whole-program analysis cannot see, so a
# devirtualized call site has to keep its dynamic fallback. Parsed with CRuby's
# bundled Prism, so it needs no gem.
#
#   ruby scripts/rpg2k_closed_world_lint.rb                  # check
#   ruby scripts/rpg2k_closed_world_lint.rb --regenerate-baseline  # shrink only
#
# Existing offences live in scripts/rpg2k_closed_world_lint_baseline.txt. The
# check fails on an offence not in the baseline, and on a baseline entry that no
# longer occurs (a ratchet: fixed code must leave the baseline too). A use that
# is genuinely data-driven is allowed in place with a trailing or preceding
#   # rpg2k-lint:allow Cop/Name -- reason
# comment; the reason is required.

require 'prism'
require 'set'

ROOT = File.expand_path('..', __dir__)
GEMS = %w[mruby-rpg2k mruby-lcf mruby-rgss].freeze
BASELINE = File.join(__dir__, 'rpg2k_closed_world_lint_baseline.txt')

COPS = {
  'Dynamic/MethodMissing' => 'method_missing/respond_to_missing? answers names no class defines',
  'Dynamic/Send' => 'send/public_send/__send__ with a computed name',
  'Dynamic/ConstReflection' => 'const_get/const_set/remove_const/autoload/const_missing',
  'Dynamic/IvarReflection' => 'instance_variable_get/set/defined?/remove_instance_variable',
  'Dynamic/MethodDefinition' => 'define_method/alias/undef/remove_method installed at runtime',
  'Dynamic/Eval' => 'eval family, instance_exec/class_exec, binding, method objects',
  'Dynamic/Extend' => 'extend on an object other than self',
  'Dynamic/RescueModifier' => '`expr rescue value` turns any StandardError into control flow'
}.freeze

SEND = %i[send public_send __send__].to_set
CONST = %i[const_get const_set remove_const autoload].to_set
IVAR = %i[instance_variable_get instance_variable_set instance_variable_defined?
          remove_instance_variable].to_set
DEFINE = %i[define_method define_singleton_method alias_method undef_method remove_method].to_set
EVAL = %i[eval instance_eval class_eval module_eval instance_exec class_exec module_exec
          binding method public_method instance_method].to_set

Offence = Struct.new(:cop, :file, :line, :snippet) do
  def key = [cop, file, snippet]
end

class Linter < Prism::Visitor
  attr_reader :offences

  def initialize(file, allowed)
    super()
    @file = file
    @allowed = allowed
    @offences = []
  end

  def visit_def_node(node)
    add('Dynamic/MethodMissing', node) if %i[method_missing respond_to_missing?].include?(node.name)
    add('Dynamic/ConstReflection', node) if node.name == :const_missing
    super
  end

  def visit_call_node(node)
    name = node.name
    if SEND.include?(name)
      first = node.arguments&.arguments&.first
      add('Dynamic/Send', node) unless first.is_a?(Prism::SymbolNode)
    end
    add('Dynamic/ConstReflection', node) if CONST.include?(name)
    add('Dynamic/IvarReflection', node) if IVAR.include?(name)
    add('Dynamic/MethodDefinition', node) if DEFINE.include?(name)
    add('Dynamic/Eval', node) if EVAL.include?(name) && eval_call?(node)
    add('Dynamic/Extend', node) if name == :extend && node.receiver && !node.receiver.is_a?(Prism::SelfNode)
    super
  end

  def visit_alias_method_node(node)
    add('Dynamic/MethodDefinition', node)
    super
  end

  def visit_undef_node(node)
    add('Dynamic/MethodDefinition', node)
    super
  end

  def visit_rescue_modifier_node(node)
    add('Dynamic/RescueModifier', node)
    super
  end

  private

  # `method`/`binding` are also common local or attribute names; only a bare or
  # self call with the reflective shape counts.
  def eval_call?(node)
    return true unless %i[method public_method instance_method binding].include?(node.name)

    node.name == :binding ? node.arguments.nil? : !node.arguments.nil?
  end

  def add(cop, node)
    line = node.location.start_line
    return if @allowed[line]&.include?(cop)

    snippet = node.slice.lines.first.strip.gsub(/\s+/, ' ')[0, 100]
    @offences << Offence.new(cop, @file, line, snippet)
  end
end

ALLOW = /#\s*rpg2k-lint:allow\s+(\S+)\s+--\s+\S/

def lint_file(path, source: nil)
  rel = path.delete_prefix("#{ROOT}/")
  result = source ? Prism.parse(source) : Prism.parse_file(path)
  raise "#{rel}: #{result.errors.map(&:message).join('; ')}" unless result.errors.empty?

  # An allow comment covers its own line and, when alone on its line, the next.
  allowed = Hash.new { |h, k| h[k] = Set.new }
  bad = []
  result.comments.each do |c|
    text = c.location.slice
    next unless text.include?('rpg2k-lint:allow')

    m = text.match(ALLOW)
    unless m && COPS.key?(m[1])
      bad << "#{rel}:#{c.location.start_line}: malformed rpg2k-lint:allow (need `Cop/Name -- reason`)"
      next
    end
    line = c.location.start_line
    allowed[line] << m[1]
    allowed[line + 1] << m[1]
  end
  linter = Linter.new(rel, allowed)
  result.value.accept(linter)
  [linter.offences, bad]
end

def load_baseline
  return Hash.new(0) unless File.exist?(BASELINE)

  File.readlines(BASELINE, chomp: true).each_with_object(Hash.new(0)) do |l, h|
    next if l.empty? || l.start_with?('#')

    count, cop, file, snippet = l.split("\t", 4)
    h[[cop, file, snippet]] = count.to_i
  end
end

return unless $PROGRAM_NAME == __FILE__

files = GEMS.flat_map { |g| Dir[File.join(ROOT, g, 'mrblib', '**', '*.rb')] }.sort
offences = []
malformed = []
files.each do |f|
  o, bad = lint_file(f)
  offences.concat(o)
  malformed.concat(bad)
end
counts = offences.group_by(&:key).transform_values(&:size)

if ARGV.include?('--regenerate-baseline')
  grown = counts.select { |key, n| n > load_baseline[key] }
  if !grown.empty? && File.exist?(BASELINE) && !ARGV.include?('--accept-new')
    grown.each_key { |(cop, file, snippet)| warn "new: #{file}: #{cop}: #{snippet}" }
    abort 'refusing to add offences to the baseline; fix them, allow them in place, or pass --accept-new'
  end
  File.open(BASELINE, 'w') do |io|
    io.puts '# rpg2k_closed_world_lint.rb baseline: count<TAB>cop<TAB>file<TAB>snippet.'
    io.puts '# Regenerate with --regenerate-baseline; entries may only disappear.'
    counts.sort.each { |(cop, file, snippet), n| io.puts [n, cop, file, snippet].join("\t") }
  end
  puts "wrote #{counts.size} baseline entries (#{offences.size} offences)"
  exit 0
end

baseline = load_baseline
new_offences = offences.select do |o|
  counts[o.key] > baseline[o.key]
end
stale = baseline.select { |key, n| counts[key] < n }

by_cop = offences.group_by(&:cop).transform_values(&:size)
COPS.each_key { |cop| puts format('  %-26s %4d', cop, by_cop.fetch(cop, 0)) }
malformed.each { |m| warn m }
new_offences.uniq(&:key).each do |o|
  warn "#{o.file}:#{o.line}: #{o.cop}: #{COPS[o.cop]}\n    #{o.snippet}"
end
stale.each do |(cop, file, snippet), n|
  warn "#{file}: #{cop}: baseline expects #{n}, found #{counts[[cop, file, snippet]]} -- " \
       "remove it with --regenerate-baseline\n    #{snippet}"
end

if new_offences.empty? && stale.empty? && malformed.empty?
  puts "rpg2k closed-world lint: PASS (#{offences.size} baselined offence(s) in #{files.size} files)"
else
  warn 'rpg2k closed-world lint: FAIL'
  exit 1
end
