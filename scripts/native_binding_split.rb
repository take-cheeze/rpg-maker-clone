#!/usr/bin/env ruby
# frozen_string_literal: true

# Split RGSS native bindings into a frame-independent direct entry point and a
# thin mrb_get_args wrapper (ADR 0263).
#
#   scripts/native_binding_split.rb report   classify every binding, write nothing
#   scripts/native_binding_split.rb write    rewrite lib.cxx, the header and the
#                                            compiler's table for the splittable set
#   scripts/native_binding_split.rb check    fail when `write` would change anything
#
# The facts come from scripts/native_binding_facts.py (libclang), run once per
# configuration (host, wio, psp, maix, emscripten); see that file for how to get
# libclang and the headers. Options:
#   --facts DIR     read facts_<config>.json from DIR instead of running it
#   --configs a,b   only those configurations
#   --root DIR      the checkout to read and rewrite (default: this one)
require 'fileutils'
require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../tools/bc2cpp/native_binding_split_rewrite'

ROOT = File.expand_path('..', __dir__)
NBS = NativeBindingSplit

options = { facts: nil, configs: NBS::CONFIGS, root: ROOT }
OptionParser.new do |o|
  o.on('--facts DIR') { |v| options[:facts] = v }
  o.on('--configs LIST') { |v| options[:configs] = v.split(',') }
  o.on('--root DIR') { |v| options[:root] = File.expand_path(v) }
end.parse!
command = ARGV.shift || 'report'
root = options[:root]

def extract(root, configs, dir)
  FileUtils.mkdir_p(dir)
  configs.to_h do |config|
    out = File.join(dir, "facts_#{config}.json")
    _stdout, err, status = Open3.capture3('python3', File.join(ROOT, 'scripts/native_binding_facts.py'),
                                          '--root', root, '--config', config, '--out', out)
    abort "native_binding_facts.py failed for #{config}:\n#{err}" unless status.success?
    [config, out]
  end
end

# Everything the commands need about the tree as it is now.
State = Struct.new(:facts, :sources, :bindings, :problems, :units, :rejected)

def load_state(root, options, scratch)
  paths =
    if options[:facts]
      options[:configs].to_h { |c| [c, File.join(options[:facts], "facts_#{c}.json")] }
    else
      extract(root, options[:configs], scratch)
    end
  facts = NBS.load_facts(paths, root)
  sources = {}
  facts.by_config.each_value do |data|
    data['files'].each_key { |file| sources[file] ||= NBS::Source.new(File.join(root, file)) }
  end
  bindings, problems = NBS.classify_all(facts, sources)
  problems.concat(NBS.apply_presence(bindings, facts))
  names = Set.new
  facts.by_config.each_value do |data|
    data['files'].each_value do |f|
      names.merge(f['functions'].keys)
      f['exports'].each { |e| names << e['name'] }
    end
  end
  header_file = File.join(root, NBS::HEADER_PATH)
  File.read(header_file).scan(/\b(\w+_direct)\s*\(/) { |(n)| names << n } if File.exist?(header_file)
  File.read(File.join(root, 'include/rgss_construct.hxx')).scan(/\b(\w+_direct)\s*\(/) { |(n)| names << n }
  units, rejected = NBS.plan_units(bindings, sources, names)
  rejected.each do |binding, why|
    binding.verdict = NBS::Verdict.new(status: :refused, reasons: [['rewrite_shape', why]])
  end
  State.new(facts, sources, bindings, problems, units, rejected)
end

# The entry point each binding has once the plan is applied: the planned split
# names, and the generated forwarders' own names (an in-block delegation may
# still carry an older name).
def planned_names(state, forwarders)
  planned = state.units.each_with_object({}) { |u, h| u.bindings.each { |b| h[b] = u.direct_name } }
  by_callee = forwarders.to_h { |f| [[f.file, f.callee], f.direct_name] }
  state.bindings.each do |b|
    t = b.reg['target']
    next unless b.owner && %i[delegated split frame_free].include?(b.verdict.status)

    callee = b.verdict.status == :split ? t['ret_call']['callee'] : t['name']
    planned[b] ||= by_callee[[b.file, callee]]
  end
  planned.compact
end

def print_report(state, facts_configs)
  puts NBS.report_lines(state.bindings)
  counts, primary, any = NBS.summary(state.bindings)
  puts
  puts "configurations: #{facts_configs.join(', ')}"
  puts "registrations: #{state.bindings.size} (#{state.bindings.map { |b| unit_id(b) }.uniq.size} distinct bound functions): " +
       state.bindings.group_by(&:api).sort.map { |api, list| "#{list.size} #{api}" }.join(', ')
  NBS::STATUS_ORDER.each { |s| puts format('  %-11s %d', s, counts[s]) }
  unapplied = state.bindings.count { |b| %i[splittable frame_free].include?(b.verdict.status) && b.owner.nil? }
  puts "  (splittable or frame-free but not applied, class owner unresolved: #{unapplied})" if unapplied.positive?
  puts "rewrite plan: #{state.units.size} units (#{state.units.count(&:splittable)} splits, " \
       "#{state.units.count { |u| !u.splittable }} frame-free forwarders), #{state.rejected.size} rejected by shape"
  return if primary.empty?

  puts 'refused, by primary reason (registrations that have the reason at all in parentheses):'
  primary.sort_by { |r, n| [-n, r] }.each { |r, n| puts format('  %-42s %3d (%d)', r, n, any[r]) }
end

def unit_id(binding)
  t = binding.reg['target']
  [binding.file, t['usr'] || t['lambda_extent'] || t['name']]
end

def write_file(root, rel, bytes)
  path = File.join(root, rel)
  File.binwrite(path, bytes)
end

# Insert or replace the generated block before the gem init function's comment.
def install_block(source, block)
  bytes = source.bytes
  range = NBS.block_range(source)
  return NBS.apply_edits(bytes, [NBS::Edit.new(range[0], range[1] + 1, block)]) if range

  anchor = bytes.index(/^extern "C" void mrb_mruby_rgss_gem_init\(/) or abort 'no gem init function to anchor the block'
  at = NBS.comment_block_start(bytes, anchor)
  NBS.apply_edits(bytes, [NBS::Edit.new(at, at, "#{block}\n")])
end

def ensure_include(root)
  path = File.join(root, 'include/rgss_construct.hxx')
  text = File.read(path)
  line = "#include \"rgss_native_direct.hxx\"\n"
  return if text.include?(line)

  File.write(path, "#{text.chomp}\n\n// Entry points generated by scripts/native_binding_split.rb (ADR 0263).\n#{line}")
end

# What `write` produces from a settled state.
def desired_outputs(_root, state)
  forwarders = NBS.forwarders_for(state.bindings, state.sources)
  out = {}
  state.sources.each do |file, source|
    mine = forwarders.select { |f| f.file == file }
    next if mine.empty? && NBS.block_range(source).nil?

    out[file] = install_block(source, NBS.render_block(mine))
  end
  out[NBS::HEADER_PATH] = NBS.render_header(forwarders)
  out[NBS::PROBE_PATH] = NBS.render_probe(forwarders)
  entries, conflicts = NBS.table_entries(state.bindings, planned_names(state, forwarders))
  out[NBS::TABLE_PATH] = NBS.render_table(entries)
  [out, conflicts, forwarders]
end

scratch = Dir.mktmpdir('native_binding_split')
begin
  state = load_state(root, options, scratch)
  case command
  when 'report'
    print_report(state, state.facts.by_config.keys)
    state.problems.each { |p| warn "problem: #{p}" }
    exit(state.problems.empty? ? 0 : 1)

  when 'write'
    abort 'write needs live facts (drop --facts)' if options[:facts]

    unless state.problems.empty?
      state.problems.each { |p| warn "problem: #{p}" }
      abort 'refusing to write while the configurations disagree'
    end
    # Pass 1: split the bodies and lift the lambdas.
    moved = state.units.select { |u| u.edits.any? }.to_h { |u| [u.body_name, [u.file, u.reg['target']['refs']]] }
    edits = state.units.group_by(&:file).transform_values { |us| us.flat_map(&:edits) }
    edits.each do |file, es|
      next if es.empty?

      write_file(root, file, NBS.apply_edits(state.sources[file].bytes, es))
    end
    # Pass 2 runs on the settled state: forwarders, header, table.
    state = load_state(root, options, scratch)
    problems = state.problems + NBS.moved_body_problems(moved, state.facts)
    abort "problems after the split:\n#{problems.join("\n")}" unless problems.empty?
    outputs, conflicts, forwarders = desired_outputs(root, state)
    conflicts.each { |c| warn "table conflict: #{c}" }
    outputs.each { |file, bytes| write_file(root, file, bytes) }
    ensure_include(root)
    puts "wrote #{outputs.keys.join(', ')} (#{forwarders.size} forwarders)"

  when 'check'
    problems = state.problems.dup
    state.units.each do |u|
      problems << "#{u.bindings.first.label} (#{u.cfunc || u.body_name}) is splittable but not split: run scripts/native_binding_split.rb write"
    end
    outputs, conflicts, forwarders = desired_outputs(root, state)
    conflicts.each { |c| problems << "table conflict: #{c}" }
    problems.concat(NBS.link_problems(forwarders, state.facts))
    outputs.each do |file, bytes|
      current = File.exist?(File.join(root, file)) ? File.binread(File.join(root, file)) : nil
      # clang-format re-flows the C++ files, so those compare without whitespace.
      same = file.end_with?('.rb') ? current == bytes : current && current.gsub(/\s+/n, '') == bytes.gsub(/\s+/n, '')
      next if same

      detail = ''
      if current
        a = current.gsub(/\s+/n, '')
        b = bytes.gsub(/\s+/n, '')
        at = (0...[a.size, b.size].min).find { |k| a[k] != b[k] } || [a.size, b.size].min
        detail = " (first difference near: file #{a[[at - 30, 0].max, 80].inspect} vs generated #{b[[at - 30, 0].max, 80].inspect})"
      end
      problems << "#{file} is stale: run scripts/native_binding_split.rb write#{detail}"
    end
    problems.each { |p| warn "FAIL #{p}" }
    puts(problems.empty? ? 'native binding split is fresh' : "#{problems.size} problem(s)")
    exit(problems.empty? ? 0 : 1)

  else
    abort "unknown command #{command}"
  end
ensure
  FileUtils.rm_rf(scratch)
end
