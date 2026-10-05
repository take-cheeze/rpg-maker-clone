#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'bc2cpp_fixture_runtime'

SOURCE = <<~RUBY
  class CcA
    def tag; :a; end
  end
  class CcB
    def tag; :b; end
  end
  class CcRelay
    def carry(value); value; end
    def identity; self; end
    def explicit_identity; copy = self; copy; end
    def nested(value); self.carry(value); end
    def optional(value, extra = nil); value; end
    def rest(value, *extra); value; end
    def blocked(value, &block); value; end
    def recursive(value); self.recursive(value); self.recursive(value); end
    def closure(value); [1].each { return CcB.new }; value; end
  end
  class CcSubRelay < CcRelay
    def carry(value); CcB.new; end
  end
  class CcParent
    def local_carry(value); value; end
    def run; local_carry(CcA.new).tag; end
    def poison(value); local_carry(value); end
  end
  class CcChild < CcParent
    def local_carry(value); CcB.new; end
  end
  class CcFixture
    def local_carry(value); value; end
    def implicit; local_carry(CcA.new).tag; end
    def poison_local(value); local_carry(value).tag; end
    def a; CcRelay.new.carry(CcA.new).tag; end
    def b; CcRelay.new.carry(CcB.new).tag; end
    def nested; CcRelay.new.nested(CcA.new).tag; end
    def self_chain; CcRelay.new.identity.carry(CcA.new).tag; end
    def explicit_self; CcRelay.new.explicit_identity.carry(CcB.new).tag; end
    def inherited; CcSubRelay.new.identity.carry(CcA.new).tag; end
    def array; CcRelay.new.carry([1, 2]).size; end
    def unknown(value); CcRelay.new.carry(value).tag; end
    def mixed(flag); value = flag ? CcA.new : CcB.new; CcRelay.new.carry(value).tag; end
    def nilable(flag); value = flag ? CcA.new : nil; CcRelay.new.carry(value).tag; end
    def wrong_arity; CcRelay.new.carry(CcA.new, CcB.new).tag; end
    def optional; CcRelay.new.optional(CcA.new).tag; end
    def rest; CcRelay.new.rest(CcA.new).tag; end
    def blocked; CcRelay.new.blocked(CcA.new).tag; end
    def poison(value); [CcRelay.new.optional(value), CcRelay.new.rest(value), CcRelay.new.blocked(value)]; end
    def recursive; CcRelay.new.recursive(CcA.new).tag; end
    def closure; CcRelay.new.closure(CcA.new).tag; end
  end
RUBY
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
abort 'SKIP: set MRBC' unless ENV['MRBC']
runtime = Bc2cppFixtureRuntime
Dir.mktmpdir('call-context') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: %w[CcA CcB CcRelay CcSubRelay CcParent CcChild CcFixture])
  body = ->(name) { code[/mrb_value CcFixture_#{name}_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s }
  enabled = ENV['BC2CPP_CALL_CONTEXT_RESULTS'] != '0'
  { 'implicit' => 'CcA', 'a' => 'CcA', 'b' => 'CcB', 'nested' => 'CcA', 'self_chain' => 'CcA', 'explicit_self' => 'CcB', 'inherited' => 'CcB' }.each do |name, klass|
    check.call("#{name}: context carries exact receiver", body.call(name).include?("EXACT_CLASS :tag -> #{klass}#tag") == enabled)
  end
  check.call('array: context carries core receiver', body.call('array').include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array') == enabled)
  %w[unknown mixed nilable wrong_arity recursive closure optional rest blocked].each do |name|
    check.call("#{name}: uncertain result stays dynamic", !body.call(name).include?('EXACT_CLASS :tag ->'))
  end
  parent_body = code[/mrb_value CcParent_run_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s
  check.call('subclassed lexical self stays unresolved', !parent_body.include?('EXACT_CLASS :tag -> CcA#tag'))
  outside = File.join(dir, 'outside')
  FileUtils.mkdir_p(File.join(outside, 'cc-foreign/mrblib'))
  outside_code, outside_err = runtime.generate(SOURCE, outside, only_owners: %w[CcA CcB CcRelay CcSubRelay CcParent CcChild CcFixture],
                                   foreign: [['cc-foreign/mrblib/carry.rb', 'class CcRelay; def carry(value); CcB.new; end; end']],
                                   build_gems: [['cc-foreign', File.join(outside, 'cc-foreign')]])
  if ENV['BC2CPP_KEEP_DIR']
    FileUtils.cp_r(dir, ENV['BC2CPP_KEEP_DIR'], remove_destination: true)
    File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'outside.err'), outside_err)
  end
  outside_body = outside_code[/mrb_value CcFixture_a_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s
  check.call('outside replacement withdraws the input-specific receiver', !outside_body.include?('EXACT_CLASS :tag -> CcA#tag'))
  unless ENV['CC_GENERATED_ONLY'] == '1'
    build = runtime.full_or_build
    if build
      harness = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value fixture = mrb_obj_new(M, mrb_class_get(M, "CcFixture"), 0, nullptr);
          for (const char* name : {"implicit", "a", "b", "nested", "self_chain", "explicit_self", "inherited", "array", "wrong_arity", "closure", "optional", "rest", "blocked"})
            call(M, name, fixture, name);
          for (mrb_value flag : {mrb_true_value(), mrb_false_value()}) {
            call(M, "mixed", fixture, "mixed", 1, &flag);
            call(M, "nilable", fixture, "nilable", 1, &flag);
          }
          for (const char* klass : {"CcA", "CcB"}) {
            mrb_value value = mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr);
            call(M, "unknown", fixture, "unknown", 1, &value);
          }
          for (const char* klass : {"CcParent", "CcChild"}) {
            mrb_value value = mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr);
            call(M, klass, value, "run");
          }
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, %w[CcA CcB CcRelay CcSubRelay CcParent CcChild CcFixture], harness, build: build, full: true)
      sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
      check.call('runtime matches interpreter', built && sections['compiled'] == sections['interpreted'])
      warn output unless built && sections['compiled'] == sections['interpreted']
    else
      puts 'SKIP runtime: no full-core build'
    end
  end
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp call context results check: PASS'
