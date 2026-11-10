#!/usr/bin/env ruby
# frozen_string_literal: true

# OWNER_CALL_DIRECT native rows: OwnerCallDirect::NATIVE_DISPOSE / NATIVE_DISPOSE_OWNERS must match the RGSS `dispose`
# ROM entries in mruby-rgss/src/lib.cxx (owner, body, arity), and each exported wrapper must be defined once at file
# scope, outside the anonymous namespace its body lives in.

require_relative '../../tools/bc2cpp/world_root'
require 'set'
ROOT = BC2CPP_WORLD_ROOT
$LOAD_PATH.unshift(File.join(BC2CPP_TREE_ROOT, 'tools/bc2cpp'))
require 'native_direct'
require 'native_owner_map'
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

abort "owner_call_direct_native_check: #{failures.size} failed" unless failures.empty?
puts 'owner_call_direct_native_check: all passed'
