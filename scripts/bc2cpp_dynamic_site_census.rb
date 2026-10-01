#!/usr/bin/env ruby
# frozen_string_literal: true

# Census of the dynamic dispatch left in bc2cpp's generated C++.
#
# Usage:
#   BC2CPP_COVERAGE_KEEP_DIR=DIR MRBC=... ruby scripts/bc2cpp_coverage_report.rb
#   ruby scripts/bc2cpp_dynamic_site_census.rb DIR/shipped.cxx [--tsv sites.tsv]
#
# Counts by-name dispatch (`bc2cpp_send`, `mrb_funcall*`, `mrb_yield_argv`) split
# into call sites in generated methods and the by-name calls held inside shared
# helpers, and classifies every `bc2cpp_send` site by its neighbouring
# diagnostics. See docs/bc2cpp-dynamic-site-census.md for the method and its
# limits. Output is stats only.

path = ARGV.shift or abort "usage: #{$PROGRAM_NAME} shipped.cxx [--tsv FILE]"
tsv = ARGV[0] == '--tsv' ? ARGV[1] : nil
src = File.read(path)
lines = src.lines
names = src[/bc2cpp_sym_names\[\d+\] = \{(.*?)\n\};/m, 1].to_s.scan(/^\s*"((?:[^"\\]|\\.)*)",/).flatten
abort 'bc2cpp_sym_names table not found' if names.empty?

# Shared helpers precede the first generated method body.
first_method = lines.index { |l| l =~ /^static mrb_value \w+_impl\(.*\{\s*$/ } or abort 'no generated method found'

fn_re = /^(?:\[\[[^\]]*\]\]\s*)*(?:static |inline )+[\w:*&<>\s]+?\b(\w+)\(.*\{\s*$/
send_re = /bc2cpp_send\(M, [^,]+, (\d+), (\d+)/
fam_re = %r{^\s*//\s*([A-Z][A-Z0-9_]+)\b}

# Where the receiver register was last assigned before the guard chain. Heuristic: a
# register copy hides the real origin, so "register_copy" is a floor on what is unknown.
def receiver_origin(lines, line, recv)
  i = line - 2
  i -= 1 while i.positive? && line - i < 80 && !(lines[i] =~ %r{^(if \(|\{$|// [^ ]+ -- generated)} && lines[i - 1] !~ /\} else|else\s*$/)
  (1..60).each do |k|
    x = lines[i - k] or break
    next unless x =~ /^\s*#{recv} = (.*);\s*$/

    return case Regexp.last_match(1)
           when /mrb_iv_get/ then 'ivar_read'
           when /_ivars\*\)DATA_PTR/ then 'embedded_ivar'
           when /bc2cpp_getidx|bc2cpp_ary_entry|mrb_hash_get/ then 'indexed_result'
           when /bc2cpp_cconst|mrb_const_get|bc2cpp_const_try/ then 'constant'
           when /upvar/ then 'captured_upvar'
           when /\A(?:r\d+|self)\z/ then 'register_copy'
           when /_impl\(/ then 'direct_call_result'
           when /bc2cpp_send|mrb_funcall|bc2cpp_slow|bc2cpp_eqq/ then 'dynamic_call_result'
           when /mrb_ary_new|mrb_hash_new|mrb_str_new|mrb_obj_new|mrb_float_value|mrb_fixnum_value|mrb_int_value/ then 'literal_or_fresh'
           else 'other'
           end
  end
  'unknown'
end

sites = []
helper_sends = Hash.new(0)
cur = nil
lines.each_with_index do |l, i|
  cur = Regexp.last_match(1) if l =~ fn_re
  next unless l =~ send_re

  idx = Regexp.last_match(1).to_i
  argc = Regexp.last_match(2).to_i
  name = names[idx]
  if i < first_method
    helper_sends[[cur, name]] += 1
    next
  end
  prev = lines[0...i].reverse.find { |x| x !~ /^\s*$/ }.to_s
  class_arm = prev =~ /(?:if|else if) \(.*(?:bc2cpp_owner_class_\d+\(M\) == mrb_obj_class|native_class ==)/ ? true : false
  else_arm = prev =~ /\belse\s*\{?\s*$/ || prev =~ /if \(!\w*(?:done|ok)\w*\)/ ? true : false
  ctx = lines[[i - 25, 0].max...i].reverse
  diag = ctx.first(10).find { |c| c.include?('POLY_DIAG') }
  marker = nil
  ctx.each do |c|
    next if c.include?('POLY_DIAG')

    if c =~ fam_re
      marker = Regexp.last_match(1)
      break
    elsif c =~ %r{^\s*// RGSS }
      marker = 'RGSS'
      break
    end
  end
  marker ||= 'NONE'
  guard = ctx.first(8).reject { |c| c =~ %r{^\s*//} }.join
  shape = case guard
          when /bc2cpp_owner_class_\d+\(M\) == mrb_obj_class/ then 'owner_class_chain'
          when /native_class ==|rgss::native_\w+_class\(\)/ then 'rgss_native_class_guard'
          when /M->(?:array|hash|string|range)_class/ then 'core_exact_class_chain'
          when /mrb_integer_p|mrb_float_p|mrb_fixnum_p/ then 'numeric_tag_guard'
          when /mrb_obj_class\(M, \w+\) ==|->c == / then 'other_class_guard'
          else 'no_guard_nearby'
          end
  why = if diag
          "#{diag[/path=(\w+)/, 1]}/#{diag[/receiver=(\w+)/, 1]}/#{diag[/origin=([\w:.]+)/, 1] || '-'}"
        else
          'no_diag'
        end
  kept = l[/CLOSED_WORLD kept: (\w+)/, 1]
  origin = receiver_origin(lines, i + 1, l[/bc2cpp_send\(M, (\w+)/, 1])
  category = if kept then "closed_world_kept:#{kept}"
             elsif class_arm then 'known_class_arm_still_by_name'
             elsif shape == 'rgss_native_class_guard' then 'rgss_native_exact_class_else'
             elsif shape == 'core_exact_class_chain'
               %w[ivar_read embedded_ivar].include?(origin) ? 'core_tag_chain_else:receiver_is_ivar' : 'core_tag_chain_else:receiver_other'
             elsif diag then "poly_diag:#{why.split('/').first(2).join('/')}"
             elsif shape == 'owner_class_chain' then 'owner_chain_default_else'
             else "other:#{shape}"
             end
  sites << { line: i + 1, origin: origin, category: category, kept: kept, fn: cur, name: name, argc: argc, else_arm: else_arm, class_arm: class_arm, marker: marker, shape: shape, why: why,
             excluded: diag && diag[/excluded=(\S+)/, 1] }
end

def tally(rows, key)
  rows.group_by(&key).transform_values(&:size).sort_by { |k, v| [-v, k.to_s] }
end

def show(title, pairs, limit = nil)
  puts "-- #{title} --"
  (limit ? pairs.first(limit) : pairs).each { |k, v| puts format('%6d  %s', v, k) }
end

body_count = ->(re) { lines.each_with_index.count { |l, i| l =~ re && l !~ %r{^\s*//} && i >= first_method } }
helper_count = ->(re) { lines[0...first_method].count { |l| l =~ re && l !~ %r{^\s*//} } }

puts "file: #{File.basename(path)} (#{lines.size} lines); helper region = lines 1..#{first_method}"
puts
puts '-- raw counts (generated-method bodies; helper-region counts in parentheses) --'
puts format('bc2cpp_send call sites:              %6d (%d)', sites.size, helper_sends.values.sum)
puts format('mrb_funcall_with_block:              %6d (%d)', body_count.(/mrb_funcall_with_block\(/), helper_count.(/mrb_funcall_with_block\(/))
puts format('BLOCK_FALLBACK markers:              %6d', lines.count { |l| l.include?('BLOCK_FALLBACK :') })
puts format('mrb_funcall(_argv/_id):              %6d (%d)', body_count.(/\bmrb_funcall(?:_argv|_id)?\(/), helper_count.(/\bmrb_funcall(?:_argv|_id)?\(/))
puts format('mrb_yield_argv:                      %6d (%d)', body_count.(/\bmrb_yield_argv\(/), helper_count.(/\bmrb_yield_argv\(/))
puts format('bc2cpp_nomethod sites (not dynamic): %6d', body_count.(/bc2cpp_nomethod\(/))
puts

puts '-- by-name calls held inside shared helpers (and how many generated call sites reach each) --'
helper_sends.group_by { |(f, _), _| f }.each do |f, rows|
  callers = lines.each_with_index.count { |l, i| i >= first_method && l =~ /\b#{Regexp.escape(f.to_s)}\(/ }
  puts format('%-26<f>s %-10<n>s by-name calls:%<c>d  generated callers:%<k>d',
              f: f, n: rows.map { |(_, n), _| n }.uniq.join(','), c: rows.sum { |_, c| c }, k: callers)
end
puts

show('else-arm of an inline fast path vs only dispatch', tally(sites, ->(s) { s[:class_arm] ? 'known-class arm (class proven, still by name)' : (s[:else_arm] ? 'fast-path else-arm' : 'bare dispatch') }))
puts
show('category (exclusive; first matching rule wins)', tally(sites, ->(s) { s[:category] }), 30)
puts
show('receiver origin (heuristic)', tally(sites, ->(s) { s[:origin] }))
puts
show('guard shape guarding the dispatch (code immediately before the site)', tally(sites, ->(s) { s[:shape] }))
puts
show('marker family (nearest preceding family comment)', tally(sites, ->(s) { s[:marker] }), 30)
puts
show('why dynamic (POLY_DIAG path/receiver/origin)', tally(sites, ->(s) { s[:why] }), 40)
puts
show('why dynamic, path only', tally(sites, ->(s) { s[:why].split('/').first }))
puts
show('why dynamic, receiver only', tally(sites, ->(s) { s[:why].split('/')[1] || '-' }))
puts
show('why dynamic, origin only', tally(sites, ->(s) { s[:why].split('/')[2] || '-' }))
puts
show('excluded= reasons', sites.flat_map { |s| (s[:excluded] || '').split(',').map { |e| e.sub(/=\d+\z/, '') } }.reject(&:empty?).tally.sort_by { |k, v| [-v, k] })
puts
show('TOP 40 method names', tally(sites, ->(s) { s[:name] }), 40)

if tsv
  File.open(tsv, 'w') do |f|
    sites.each { |s| f.puts [s[:line], s[:fn], s[:name], s[:argc], s[:class_arm] ? 'class_arm' : s[:else_arm], s[:marker], s[:shape], s[:origin], s[:category], s[:why]].join("\t") }
  end
end
