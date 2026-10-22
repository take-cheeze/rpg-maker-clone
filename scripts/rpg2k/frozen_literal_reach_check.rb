#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Frozen-literal reachability audit (docs/frozen-string-literal-audit.md).
#
# For every in-place mutation of a local that has no earlier write in its scope (a method parameter, a block parameter,
# or a local the scope only writes after the call), trace where the value comes from and classify it:
#
#   literal        a plain String literal can be the receiver (the call path is listed)
#   not-reachable  every origin is a fresh String, a non-String literal, or a non-String value
#   unknown        an origin could not be traced (native or data entry, core method result, block yield, splat)
#
# Origins are followed through parameters (to every caller's argument), locals and instance variables (to every
# writer's value), and method results (to the callee's last expression). Depth is bounded by MAX_DEPTH.
#
# Limits. Callers, writers and definitions are matched by name across all of mrblib, so a literal verdict can be an
# over-approximation (any same-named method counts). A not-reachable verdict is only as good as that matching: a call
# made through send, public_send or method(:name), or from native code, is not seen. Block parameters are not traced.
# Memoised origins keep the depth they were first reached at.
#
# Usage: ruby scripts/rpg2k/frozen_literal_reach_check.rb            prints the report as markdown
#        ruby scripts/rpg2k/frozen_literal_reach_check.rb --check    fails when the committed report differs
require 'prism'
require 'set'

ROOT = File.expand_path('../..', __dir__)
REPORT = File.join(ROOT, 'docs', 'frozen-string-literal-audit.md')
MUT = %i[<< concat prepend insert replace []= clear chomp! strip! lstrip! rstrip! sub! gsub! squeeze! force_encoding
         setbyte slice! upcase! downcase! capitalize! swapcase! reverse! tr! tr_s! delete! succ! next! encode!
         unicode_normalize!].freeze
MAX_DEPTH = 8
# Core String methods that always build a new String (never return the receiver or a stored object).
FRESH_STRING_METHODS = %i[byteslice slice strip lstrip rstrip chomp chop downcase upcase capitalize swapcase reverse
                          succ ljust rjust center sub gsub tr delete squeeze join + * %].freeze
WRITE_NODES = [Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
               Prism::LocalVariableOperatorWriteNode].freeze

Site = Struct.new(:file, :line, :method, :recv, :origin, :verdict, :why, :path, keyword_init: true)
Verdict = Struct.new(:kind, :why, :path, keyword_init: true)

FILES = Dir.glob(File.join(ROOT, 'mruby-*/mrblib/**/*.rb')).sort
PARSED = FILES.to_h { |f| [f, Prism.parse(File.binread(f).force_encoding('UTF-8')).value] }
REL = ->(f) { f.delete_prefix("#{ROOT}/") }

# Visit every node with a copy of its ancestors (outermost first); the walk mutates its own stack as it descends.
def walk(node, stack = [], &blk)
  return unless node

  yield node, stack.dup
  stack.push(node)
  node.compact_child_nodes.each { |c| walk(c, stack, &blk) }
  stack.pop
end

# The nearest DefNode ancestor, or nil at class or file level.
def scope_def(stack)
  stack.reverse.find { |n| n.is_a?(Prism::DefNode) }
end

def param_nodes(node)
  params = case node
           when Prism::DefNode then node.parameters
           when Prism::BlockNode, Prism::LambdaNode then node.parameters&.parameters
           end
  return [] unless params.is_a?(Prism::ParametersNode) || params.is_a?(Prism::BlockParametersNode)

  inner = params.is_a?(Prism::BlockParametersNode) ? params.parameters : params
  return [] unless inner

  (inner.requireds + inner.optionals + inner.keywords + [inner.rest, inner.keyword_rest, inner.block]).compact
end

# The innermost def or block ancestor that declares +name+ as a parameter, or nil.
def binding_owner(name, stack)
  stack.reverse.find { |n| param_nodes(n).any? { |p| p.respond_to?(:name) && p.name == name } }
end

# Writes to local +name+ in file +root+ whose nearest DefNode is +scope+ (nil for class and file level), as
# [node, ancestors].
def local_writes(root, scope, name)
  WRITES_CACHE.fetch([root.object_id, scope&.object_id, name]) do
    writes = []
    walk(root) do |n, stack|
      next unless WRITE_NODES.any? { |k| n.is_a?(k) } && n.name == name
      next unless scope_def(stack) == scope

      writes << [n, stack]
    end
    WRITES_CACHE[[root.object_id, scope&.object_id, name]] = writes
  end
end

def init_kind(value)
  case value
  when Prism::StringNode then :literal
  when Prism::InterpolatedStringNode then :fresh
  when Prism::CallNode
    if value.name == :+@ && value.receiver.is_a?(Prism::StringNode) then :fresh
    elsif %i[dup clone].include?(value.name) && value.receiver.is_a?(Prism::StringNode) then :fresh
    elsif value.name == :new && value.receiver.is_a?(Prism::ConstantReadNode) && value.receiver.name == :String then :fresh
    else :other
    end
  when Prism::IntegerNode, Prism::FloatNode, Prism::SymbolNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode,
       Prism::ArrayNode, Prism::HashNode, Prism::RangeNode, Prism::LambdaNode then :non_string
  else :other
  end
end

# Classes in the corpus that subclass String: their instances can be literal-derived, so `Klass.new` is not a
# non-String origin for them.
STRING_SUBCLASSES = Set.new
PARSED.each_value do |root|
  walk(root) do |n, _|
    next unless n.is_a?(Prism::ClassNode) && n.superclass.is_a?(Prism::ConstantReadNode) && n.superclass.name == :String

    STRING_SUBCLASSES << n.constant_path.slice.split('::').last
  end
end
# `Const.new` where Const is not String and not a corpus String subclass: its instance is not a String literal.
NON_STRING_CONSTANT = lambda do |recv|
  return false unless recv.is_a?(Prism::ConstantReadNode)

  recv.name.to_s != 'String' && !STRING_SUBCLASSES.include?(recv.name.to_s)
end

# Every method definition in the corpus, by name.
DEFS = Hash.new { |h, k| h[k] = [] }
PARSED.each_value { |root| walk(root) { |n, _| DEFS[n.name.to_s] << n if n.is_a?(Prism::DefNode) } }

def callers_of(name)
  CALLERS.fetch(name) do
    out = []
    PARSED.each do |file, root|
      walk(root) { |n, stack| out << [file, n, stack] if n.is_a?(Prism::CallNode) && n.name.to_s == name }
    end
    CALLERS[name] = out
  end
end

def call_site(file, call)
  "#{REL.call(file)}:#{call.location.start_line} #{call.name}"
end

def verdict(kind, why, path = [])
  Verdict.new(kind: kind, why: why, path: path)
end

# Memoised lookups: each origin is traced once. The placeholder set before the computation breaks cycles (a value
# written from itself, or a method that calls itself).
MEMO = {}
def memo(key)
  return MEMO[key] if MEMO.key?(key)

  MEMO[key] = verdict(:unknown, 'cycle in the origin chain')
  MEMO[key] = yield
end

CALLERS = Hash.new { |h, k| h[k] = [] }
WRITES_CACHE = {}

# Combine the verdicts of several origins: any literal wins (with its path), all not-reachable is not-reachable.
def combine(verdicts, what)
  lit = verdicts.find { |v| v.kind == :literal }
  return verdict(:literal, lit.why, lit.path) if lit
  return verdict(:not_reachable, "all #{verdicts.size} #{what} are fresh or non-String") if verdicts.all? { |v| v.kind == :not_reachable }
  return verdict(:unknown, verdicts.find { |v| v.kind == :unknown }.why) if verdicts.any? { |v| v.kind == :unknown }

  verdict(:unknown, "no #{what} traced")
end

# The origin of the value of an expression at a site with ancestors +stack+.
def classify_value(expr, stack, depth)
  return verdict(:unknown, 'depth limit reached') if depth > MAX_DEPTH

  case expr
  when Prism::StringNode then verdict(:literal, 'plain String literal')
  when Prism::LocalVariableReadNode then classify_local(expr.name, stack, depth)
  when Prism::InstanceVariableReadNode then classify_ivar(expr.name, depth)
  when Prism::ParenthesesNode
    last = expr.body&.compact_child_nodes&.last
    last ? classify_value(last, stack, depth + 1) : verdict(:not_reachable, 'empty parentheses')
  when Prism::OrNode, Prism::AndNode
    combine([expr.left, expr.right].map { |e| classify_value(e, stack, depth + 1) }, 'operands')
  when Prism::CallNode
    if init_kind(expr) == :fresh
      verdict(:not_reachable, "fresh String (#{expr.name} of a literal)")
    elsif expr.name == :new && NON_STRING_CONSTANT.call(expr.receiver)
      verdict(:not_reachable, "instance of #{expr.receiver.name} (not a String subclass in mrblib)")
    else
      classify_call_result(expr, depth)
    end
  else
    case init_kind(expr)
    when :fresh then verdict(:not_reachable, 'fresh String (interpolation)')
    when :non_string then verdict(:not_reachable, "non-String value (#{expr.class.name.split('::').last})")
    else verdict(:unknown, "unmodelled expression #{expr.class.name.split('::').last}")
    end
  end
end

def classify_local(name, stack, depth)
  owner = binding_owner(name, stack)
  return classify_param(owner, name, depth) if owner

  scope = scope_def(stack)
  memo([:local, stack.first.object_id, scope&.object_id, name]) { classify_local_writes(stack.first, scope, name, depth) }
end

def classify_local_writes(root, scope, name, depth)
  writes = local_writes(root, scope, name)
  return verdict(:unknown, "local #{name} has no write in its scope") if writes.empty?

  verdicts = writes.map do |w, wstack|
    v = classify_value(w.value, wstack, depth + 1)
    verdict(v.kind, "local #{name} (line #{w.location.start_line}): #{v.why}", v.path)
  end
  combine(verdicts, 'writers')
end

def classify_ivar(name, depth)
  memo([:ivar, name]) { classify_ivar_writes(name, depth) }
end

def classify_ivar_writes(name, depth)
  writes = []
  PARSED.each do |file, root|
    walk(root) do |n, stack|
      writes << [file, n, stack] if n.is_a?(Prism::InstanceVariableWriteNode) && n.name == name
    end
  end
  return verdict(:unknown, "ivar #{name} is never written in mrblib") if writes.empty?

  verdicts = writes.map do |file, w, wstack|
    v = classify_value(w.value, wstack, depth + 1)
    verdict(v.kind, "ivar #{name} written at #{REL.call(file)}:#{w.location.start_line}: #{v.why}", v.path)
  end
  combine(verdicts, 'writers')
end

def classify_call_result(call, depth)
  memo([:call, call.name]) { classify_call_result_uncached(call, depth) }
end

def classify_call_result_uncached(call, depth)
  defs = DEFS[call.name.to_s]
  if defs.empty? && FRESH_STRING_METHODS.include?(call.name)
    return verdict(:not_reachable, "#{call.name} always returns a new String")
  end
  return verdict(:unknown, "result of #{call.name} (core or native method)") if defs.empty?

  verdicts = defs.map do |df|
    returned = df.body&.compact_child_nodes&.last
    returned ? classify_value(returned, [df], depth + 1) : verdict(:unknown, "#{call.name} has no body")
  end
  combine(verdicts.map { |v| verdict(v.kind, "result of #{call.name}: #{v.why}", v.path) }, 'definitions')
end

# A parameter's origin: the argument every caller passes in that position.
def classify_param(owner, name, depth)
  memo([:param, owner.object_id, name]) { classify_param_uncached(owner, name, depth) }
end

def classify_param_uncached(owner, name, depth)
  return verdict(:unknown, "block parameter #{name} (the yielded value is not traced)") unless owner.is_a?(Prism::DefNode)

  index = owner.parameters&.requireds&.index { |p| p.respond_to?(:name) && p.name == name }
  return verdict(:unknown, "parameter #{name} is not a required positional") if index.nil?

  calls = callers_of(owner.name.to_s)
  return verdict(:unknown, "no caller of #{owner.name} in mrblib (native or data entry possible)") if calls.empty?

  verdicts = calls.map do |file, call, cstack|
    site = call_site(file, call)
    args = call.arguments&.arguments || []
    if args.any? { |a| a.is_a?(Prism::SplatNode) || a.is_a?(Prism::KeywordHashNode) }
      verdict(:unknown, 'caller uses splat or keywords', [site])
    elsif args[index].nil?
      verdict(:unknown, 'caller passes no argument at this position', [site])
    else
      v = classify_value(args[index], cstack, depth + 1)
      verdict(v.kind, "argument of #{owner.name} (#{v.why})", [site] + v.path)
    end
  end
  combine(verdicts, 'callers')
end

# Sites: mutating calls on a local without an earlier write in its scope (the 57 the existing audit left open).
SITES = []
PARSED.each do |file, root|
  walk(root) do |n, stack|
    next unless n.is_a?(Prism::CallNode) && MUT.include?(n.name) && n.receiver.is_a?(Prism::LocalVariableReadNode)

    scope = scope_def(stack)
    next if local_writes(root, scope, n.receiver.name).any? { |w, _| w.location.start_offset < n.location.start_offset }

    SITES << { file: file, call: n, stack: stack, name: n.receiver.name, scope: scope }
  end
end

RESULTS = SITES.map do |s|
  v = classify_value(s[:call].receiver, s[:stack], 0)
  Site.new(file: REL.call(s[:file]), line: s[:call].location.start_line,
           method: s[:scope] ? s[:scope].name.to_s : '(outside a method)', recv: s[:name].to_s,
           origin: binding_owner(s[:name], s[:stack]) ? 'parameter' : 'local', verdict: v.kind, why: v.why,
           path: v.path)
end

def render
  counts = RESULTS.group_by(&:verdict).transform_values(&:size)
  out = +"# Frozen string literal reachability audit\n\n"
  out << "Generated by `scripts/rpg2k/frozen_literal_reach_check.rb`. Do not edit by hand; regenerate with\n"
  out << "`ruby scripts/rpg2k/frozen_literal_reach_check.rb > docs/frozen-string-literal-audit.md`.\n\n"
  out << "Sites: #{RESULTS.size} (mutating calls on a parameter or on a local with no earlier write in its scope).\n\n"
  out << "| Classification | Sites |\n| --- | ---: |\n"
  %i[literal not_reachable unknown].each { |v| out << "| #{v.to_s.tr('_', '-')} | #{counts.fetch(v, 0)} |\n" }
  out << "\n## Sites\n\n"
  RESULTS.sort_by { |s| [s.file, s.line] }.each do |s|
    out << "- `#{s.file}:#{s.line}` #{s.method}: `#{s.recv}` (#{s.origin}) **#{s.verdict.to_s.tr('_', '-')}**: #{s.why}\n"
    s.path.each { |p| out << "  - #{p}\n" } if s.verdict == :literal
  end
  out
end

if ARGV.include?('--check')
  expected = render
  committed = File.exist?(REPORT) ? File.read(REPORT) : nil
  if committed == expected
    puts "frozen_literal_reach_check: report matches (#{RESULTS.size} sites)"
    exit 0
  end
  warn 'frozen_literal_reach_check: docs/frozen-string-literal-audit.md differs from the script output; regenerate it'
  exit 1
end

print render
