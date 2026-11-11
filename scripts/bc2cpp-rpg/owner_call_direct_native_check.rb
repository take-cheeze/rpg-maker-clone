#!/usr/bin/env ruby
# frozen_string_literal: true

# OWNER_CALL_DIRECT native rows: OwnerCallDirect::NATIVE_DISPOSE / NATIVE_DISPOSE_OWNERS must match the RGSS `dispose`
# ROM entries in mruby-rgss/src/lib.cxx (owner, body, arity), and each exported wrapper must be defined once at file
# scope, outside the anonymous namespace its body lives in. OwnerCallDirect::NATIVE_ROWS must match the ROM entries of
# the same engine owners (body, arity, visibility), and each of its wrappers is one OWNER_ROW of that body.

require_relative '../../tools/bc2cpp/world_root'
require 'set'
ROOT = BC2CPP_WORLD_ROOT
$LOAD_PATH.unshift(File.join(BC2CPP_TREE_ROOT, 'tools/bc2cpp'))
require 'native_direct'
require 'native_owner_map'
require 'core_native_candidates'
require 'owner_call_direct'

failures = []
check = ->(label, ok) { puts format('%-4s %s', ok ? 'ok' : 'FAIL', label); failures << label unless ok }

lib = File.join(ROOT, 'mruby-rgss/src/lib.cxx')
SRC = File.read(lib, encoding: 'UTF-8')
# The ROM tables stand for the registrations they replaced: owner from the class variable the table is installed on.
vars = NativeDirect.class_variables(NativeDirect.strip_comments(SRC), NativeDirect.sibling_param_owners(lib))
dispose = NativeOwnerMap.rom_bindings(NativeDirect.strip_comments(SRC)).filter_map do |var, singleton, name, fn|
  [vars[var], name, fn] if name == 'dispose' && !singleton
end
registered = dispose.to_h { |owner, _name, fn| [owner, fn] }

OwnerCallDirect::NATIVE_DISPOSE_OWNERS.each do |owner, body|
  check.call("#{owner}#dispose is registered to #{body}", registered[owner] == body)
  arity = SRC.scan(/MRB_MT_ENTRY\(#{body}, MRB_SYM\(dispose\), (\w+)\(\)\)/).flatten
  check.call("#{owner}#dispose takes MRB_ARGS_NONE()", !arity.empty? && arity.uniq == ['MRB_ARGS_NONE'])
end
check.call('every native dispose registration of an RGSS owner has a row',
           dispose.all? { |owner, _n, _f| !owner.start_with?('RGSS::') || OwnerCallDirect::NATIVE_DISPOSE_OWNERS.key?(owner) })

OwnerCallDirect::NATIVE_DISPOSE.each do |body, wrapper|
  defs = SRC.lines.grep(/\b#{wrapper}\(mrb_state\* M, mrb_value self\) \{/)
  check.call("#{wrapper} is defined once at file scope", defs.size == 1)
  check.call("#{wrapper} calls #{body}", SRC.include?("return #{body}(M, self);"))
end

# NATIVE_ROWS: every row is the ROM entry of its owner (CoreNativeCandidates.engine_entries reads the token-named tables).
paths = Dir[File.join(ROOT, 'mruby-rgss/src/*.cxx')] + Dir[File.join(ROOT, 'mruby-lcf/src/*.cxx')]
entries = CoreNativeCandidates.engine_entries(paths)
# The arity and visibility text of the ROM entry of `body` under `token` (MRB_MT_ENTRY's third argument, paren-matched).
flags_of = lambda do |path, token, body, cname|
  text = File.binread(path).force_encoding(Encoding::UTF_8).scrub
  from = text[/^[ \t]*#[ \t]*define[ \t]+MRB_MT_CLASS[ \t]+#{token}\b/] && text.index(/^[ \t]*#[ \t]*define[ \t]+MRB_MT_CLASS[ \t]+#{token}\b/)
  at = from && text.index(/MRB_MT_ENTRY\(\s*#{body}\s*,\s*MRB_\w+\(\s*#{Regexp.escape(cname)}\s*\)\s*,/, from)
  next nil unless at
  i = text.index(',', text.index('MRB_SYM', at)) + 1
  depth = 1
  j = i
  while depth.positive? && j < text.size
    depth += 1 if text[j] == '('
    depth -= 1 if text[j] == ')'
    j += 1
  end
  text[i...j - 1].gsub(%r{//[^\n]*}, '').gsub(/\s+/, ' ').strip
end
wrappers = paths.flat_map { |path| File.read(path, encoding: 'UTF-8').scan(/^OWNER_ROW\((\w+), (\w+)\)$/) }
check.call('every NATIVE_ROWS wrapper is defined once', wrappers.map(&:first).tally.values.all?(1) && wrappers.size == OwnerCallDirect::NATIVE_ROWS.size)
OwnerCallDirect::NATIVE_ROWS.each do |owner, name, wrapper, aspec, visibility|
  body = wrappers.to_h[wrapper]
  entry = entries.find { |e| e[:owner] == owner && e[:name] == name && e[:fn] == body }
  check.call("#{owner}##{name}: #{wrapper} wraps its ROM entry #{body.inspect}", !body.nil? && !entry.nil?)
  next unless entry

  flags = flags_of.call(entry[:path], entry[:mt_class], body, entry[:cname])
  want = visibility == :private ? "#{aspec} | MRB_MT_PRIVATE" : aspec
  check.call("#{owner}##{name}: arity and visibility are #{want}", flags == want)
end
# The rows complete an owner call only when every listed engine owner has one (OwnerCallDirect.rewrite).
rows = OwnerCallDirect.native_entries
site = ->(name, owners, guard: nil) do
  call = %(r1 = bc2cpp_owner_call_named(M, r0, "#{name}", 2, BC2CPP_OWNERS(#{owners.map { |o| %("#{o}") }.join(', ')}), mrb_nil_value(), 0, self);\n)
  guard ? "#{guard}} else {\n#{call}}\n" : call
end
rewrite = ->(code) { OwnerCallDirect.rewrite(code, rows, {}, Set.new) }
one = rewrite.call(site.call('get_pixel', ['RGSS::Bitmap']))
check.call('a call listing only RGSS::Bitmap#get_pixel carries its native row',
           one.include?('BC2CPP_OWNERS_D(BC2CPP_OWNER_DIRECT("RGSS::Bitmap", rgss_row_bitmap_get_pixel, MRB_ARGS_REQ(2), MRB_METHOD_PUBLIC_FL), "RGSS::Bitmap")'))
mixed = site.call('get_pixel', %w[RGSS::Bitmap RGSS::Tilemap])
check.call('an owner without a row keeps the plain owner set', rewrite.call(mixed) == mixed)
two = rewrite.call(site.call('_poll', %w[RGSS::Input RGSS::Input.singleton]))
check.call('a module function carries both its rows, the instance copy private',
           two.include?('BC2CPP_OWNER_DIRECT("RGSS::Input", rgss_row_input_poll, MRB_ARGS_NONE(), MRB_METHOD_PRIVATE_FL)') &&
           two.include?('BC2CPP_OWNER_DIRECT("RGSS::Input.singleton", rgss_row_input_s_poll, MRB_ARGS_NONE(), MRB_METHOD_PUBLIC_FL)'))
unknown = site.call('get_pixel', ['Game::Anything'])
check.call('an owner no row names is left alone', rewrite.call(unknown) == unknown)
ENV['BC2CPP_OWNER_CALL_DIRECT'] = '0'
check.call('BC2CPP_OWNER_CALL_DIRECT=0 keeps every call plain', rewrite.call(site.call('get_pixel', ['RGSS::Bitmap'])).include?('BC2CPP_OWNERS(') &&
           !rewrite.call(site.call('get_pixel', ['RGSS::Bitmap'])).include?('OWNERS_D'))
ENV.delete('BC2CPP_OWNER_CALL_DIRECT')
check.call('every NATIVE_ROWS wrapper is declared for the generated code',
           OwnerCallDirect::NATIVE_ROWS.all? { |_o, _n, wrapper, *_| OwnerCallDirect.native_prototypes.include?("mrb_value #{wrapper}(mrb_state* M, mrb_value self);") })
check.call('no NATIVE_ROWS row is a dispose row', OwnerCallDirect::NATIVE_ROWS.none? { |_o, n, *_| n == 'dispose' })

abort "owner_call_direct_native_check: #{failures.size} failed" unless failures.empty?
puts 'owner_call_direct_native_check: all passed'
