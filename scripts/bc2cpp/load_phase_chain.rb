#!/usr/bin/env ruby
# frozen_string_literal: true

# LOAD_PHASE_CHAIN (read-only): which load-time code sends a method name, and the chain of calls that reaches it.
#
# StaticDispatchRegistrations.load_phase (tools/bc2cpp/static_dispatch_registrations.rb) keeps the bodies that may run
# while mrblib loads, and every name their sends mention. This script compiles the same mrblib world with a host mrbc,
# runs load_phase on it, and reports for one TARGET name (default `each`):
#
#   - each send of TARGET by a load-time irep (the root, a class body, a block there, or a method body the load reaches),
#     with its file:line, the receiver kind load_phase derived for it, and its enclosing method;
#   - the chain of calls from a root or class body down to that send: each step is the call site (file:line, the name it
#     sends, the receiver kind) and the body it reaches.
#
# The chain is recovered by a mirror of load_phase's loop that records, for each body and irep, the call site that first
# reached it. The mirror must agree with load_phase's own bodies and names, or the script aborts: a change to load_phase
# that this mirror does not follow is reported, not silently mis-explained.
#
# Options (all read-only; nothing under the tree is written):
#   --target NAME          the method name to trace (default: each)
#   --engine-only          compile only the engine's Ruby (StaticDispatchRegistrations.closed_world's world); by default
#                          the core and external mrblib are compiled too, as the stub generation reads them
#                          (MrblibStubs.stubbable, bc2cpp.rb)
#   --world-list FILE      compile exactly the files named in FILE (one path per line, in order) instead of the world:
#                          e.g. the residual mrblib a closed build loads (its mrblib_stubs copies), to compare with the
#                          source world the stub generation reads
#   --replace SUFFIX=FILE  compile FILE in place of the mrblib file whose path ends with SUFFIX (e.g. a rewritten lib.rb
#                          in a scratch directory); repeatable. The tree itself is not changed.
#
# Needs MRBC (a host mrbc of this tree's mruby pin); prints a SKIP line and exits 0 without it. Exits 1 when the
# mirror and load_phase disagree, and 0 otherwise.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/load_phase_chain.rb [--target each] [--engine-only] [--replace SUFFIX=FILE]

require 'set'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)

options = { target: 'each', core: true, replace: {}, world_list: nil }
args = ARGV.dup
until args.empty?
  case (arg = args.shift)
  when '--target' then options[:target] = args.shift
  when '--engine-only' then options[:core] = false
  when '--world-list'
    list = args.shift.to_s
    abort "--world-list needs a readable FILE" unless File.file?(list)

    options[:world_list] = File.readlines(list, chomp: true).reject(&:empty?)
  when '--replace'
    suffix, file = args.shift.to_s.split('=', 2)
    abort "--replace needs SUFFIX=FILE" unless suffix && file && File.file?(file)

    options[:replace][suffix] = File.expand_path(file)
  else abort "unknown option #{arg}"
  end
end

mrbc = ENV['MRBC']
if mrbc.nil? || mrbc.empty? || !File.executable?(mrbc)
  puts 'SKIP load_phase_chain: set MRBC to a host mrbc'
  exit 0
end

# Before bc2cpp's own requires: irep.rb reads MRBC when it loads.
ENV['MRBC'] = mrbc
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

S = StaticDispatchRegistrations
SINGLETON = ->(owner) { owner.end_with?('.singleton') }
CORE = ->(owner) { !SINGLETON.call(owner) && !owner.match?(S::ENGINE_RE) }

# The mrblib files of the world, with --replace applied. The generation's world is closed_world_mrblib_srcs with the
# build's core gems; the canonical gem set is the closed build's minus mruby-dir and the Onigmo gem (compiled_gems.rb).
def world_srcs(options)
  srcs = options[:world_list] || closed_world_mrblib_srcs(ROOT, core_gems: options[:core] ? :canonical : nil)
  srcs.map do |path|
    hit = options[:replace].find { |suffix, _| path.end_with?(suffix) }
    hit ? hit[1] : path
  end
end

# [ireps, registry] of the world, as closed_world (static_dispatch_registrations.rb) builds them.
def compile_world(options)
  Dir.mktmpdir('load_phase_chain') do |tmp|
    ireps, root = compile_ireps(world_srcs(options), 'load_phase_chain', tmp, mrbc: ENV['MRBC'])
    registry = build_registry(ireps, root)[0]
    [ireps, registry]
  end
end

# Body labels and the method each irep belongs to, as analyze (static_dispatch_registrations.rb) computes them.
def method_tables(ireps, registry)
  body_of = {}
  registry.each { |name, defs| defs.each { |d| body_of[d.irep] = [d.owner, name] if d.irep } }
  parent = {}
  ireps.each_value { |irep| irep.reps.each { |c| parent[c] = irep.label } }
  method_of = {}
  ireps.each_key do |label|
    up = label
    up = parent[up] until up.nil? || body_of.key?(up)
    method_of[label] = up
  end
  [body_of, method_of]
end

# The loop of load_phase, with provenance. Returns the bodies and names load_phase must also return, plus:
#   why:   irep label => [:root] | [:via, body label, calling irep label, insn index]
#   sends: [calling irep label, insn index, name, receiver kind] for every load-time send
# Keep it in step with load_phase: the caller compares the bodies and names with load_phase's.
def trace_load_phase(ireps, body_of, method_of, overridden)
  by_name = Hash.new { |h, k| h[k] = [] }
  body_of.each { |label, (owner, name)| by_name[name] << [label, owner] }
  engine_instance = ->(owner) { !SINGLETON.call(owner) && owner.match?(S::ENGINE_RE) }
  instance_owners = overridden.map { |k| k.split('#', 2).first }.select { |o| engine_instance.call(o) }
                              .to_set { |o| o.split('::').last }
  irep_of_method = Hash.new { |h, k| h[k] = [] }
  method_of.each { |l, m| irep_of_method[m] << l if m }
  runnable = ireps.keys.select { |l| method_of[l].nil? }.to_set
  why = runnable.to_h { |l| [l, [:root]] }
  bodies = {}
  names = Set.new
  sends = []
  queue = runnable.to_a
  until queue.empty?
    label = queue.shift
    irep = ireps.fetch(label)
    recvs = S.receiver_kinds(irep)
    m = method_of[label]
    self_kind = if m.nil? then :class
                elsif SINGLETON.call(body_of[m][0]) then :class
                elsif CORE.call(body_of[m][0]) then :core
                else :instance
                end
    irep.each_with_op(*(S::SEND_OPS - [:LOADSYM])) do |insn, idx|
      name = insn.sym
      next unless name

      names << name
      recv = recvs[idx]
      recv = self_kind if recv == :self
      sends << [label, idx, name, recv]
      engine_live_possible = S::INSTANTIATING.include?(name) &&
                             (recv == :unknown || recv == :instance || (recv.is_a?(Array) && instance_owners.include?(recv[1])))
      raise 'load_phase_chain: load_phase falls back to load_phase_all_names here; the mirror does not follow it' if engine_live_possible

      targets = by_name[name].select do |_l, owner|
        case recv
        when :class, Array then SINGLETON.call(owner) || CORE.call(owner)
        when :core then CORE.call(owner)
        when :instance then !SINGLETON.call(owner)
        else SINGLETON.call(owner) || CORE.call(owner) # engine_live is never set here: the raise above
        end
      end
      targets.each do |l, _o|
        next if bodies.key?(l)

        bodies[l] = true
        irep_of_method[l].each do |k|
          next unless runnable.add?(k)

          why[k] = [:via, l, label, idx]
          queue << k
        end
      end
    end
  end
  { bodies: bodies.keys.to_set, names: names, why: why, sends: sends, runnable: runnable }
end

def site(ireps, label, idx)
  irep = ireps.fetch(label)
  insn = BytecodeIR.for(irep).each_source.to_a.find { |_, i| i == idx }&.first
  file = File.basename(irep.file.to_s)
  "#{file}:#{insn&.lineno}"
end

def where(label, ireps, body_of, method_of)
  m = method_of[label]
  m ? body_of[m].join('#') : 'a root or class body'
end

ireps, registry = compile_world(options)
body_of, method_of = method_tables(ireps, registry)
# Every plain engine def counts as overridden, as MrblibStubs.stubbable does.
overridden = body_of.each_value.map { |owner, name| "#{owner}##{name}" }.to_set
load_bodies, load_names = S.load_phase(ireps, body_of, method_of, overridden)
trace = trace_load_phase(ireps, body_of, method_of, overridden)

unless trace[:bodies] == load_bodies && trace[:names] == load_names
  abort 'load_phase_chain: the mirror of load_phase disagrees with load_phase; update trace_load_phase'
end

target = options[:target]
puts "world: #{ireps.size} ireps (#{options[:core] ? 'core and external mrblib included' : 'engine mrblib only'}), " \
     "#{options[:replace].size} replaced source(s)"
puts "load_phase: #{trace[:runnable].size} load-time ireps, #{load_bodies.size} kept bodies, " \
     "#{load_names.size} names sent at load"
puts '  kept bodies:'
load_bodies.sort_by { |l| body_of[l].join('#') }.each { |l| puts "    #{body_of[l].join('#')}  (#{File.basename(ireps[l].file.to_s)})" }

hits = trace[:sends].select { |_, _, name, _| name == target }
puts "load-time sends of #{target}: #{hits.size}"
hits.each do |label, idx, _name, recv|
  puts "  #{site(ireps, label, idx)} in #{where(label, ireps, body_of, method_of)}: recv=#{recv.inspect}"
  cur = label
  depth = 0
  loop do
    why = trace[:why][cur]
    break if why.nil? || why[0] == :root || depth > 60

    _, body, from, from_idx = why
    puts "    <- #{site(ireps, from, from_idx)} in #{where(from, ireps, body_of, method_of)} calls #{body_of[body].join('#')}"
    cur = from
    depth += 1
  end
  puts "    <- root or class body #{ireps.fetch(cur).file.then { |f| File.basename(f.to_s) }}" if depth.positive?
end

