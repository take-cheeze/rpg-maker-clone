#!/usr/bin/env ruby
# frozen_string_literal: true

# Soundness check for wio_unreachable_methods.rb (ADR 0218) on a fixture
# closed world: every way a method can be reached without a plain call site
# must keep it, and only the truly unreachable defs may be stripped. The
# stripped fixture is then loaded and run under CRuby, so a visibility list
# left naming a stripped method (a NameError at load) or a live method
# stripped by mistake (a NoMethodError) fails here too.

require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'wio_unreachable_methods'

WORLD = <<~'RUBY'
  class Base
    # Reached only through Widget's `super`. No rule needed: `super` in `def m`
    # dispatches `m`, which is live whenever that body can run.
    def via_super_only = :base_super
    def dead_in_base = 0
  end

  class Widget < Base
    def initialize(tag)
      @tag = tag
    end

    def via_super_only
      [super, :widget]
    end

    def via_symbol_proc = :sym_proc          # only `map(&:via_symbol_proc)`
    def via_native = [:native, private_helper] # only native mrb_funcall
    def private_helper = :helper
    def via_respond_to_guard = :guard        # only `respond_to?(:...)`, never called
    def via_string_literal = :string         # only a "via_string_literal" literal
    def listed_in_blob = :blob               # only inside a binary data string
    def via_interpolated_name = :interp      # only :"via_#{kind}_name"
    def via_outside_ruby = :outside          # only from code outside the world
    def natively_defined_too = :dead         # native code only *defines* this name
    def truly_dead = :dead                   # nothing reaches it
    def dead_helper = :dead                  # called only by another dead def
    def dead_caller = dead_helper

    def to_s = "Widget(#{@tag})"             # a VM hook, never named

    private :truly_dead, :private_helper,
            :dead_caller

    class << self
      def build = new(:built)
      def dead_singleton = :dead
    end
  end

  module Helpers
    def used_helper = :used
    def dead_function = :dead
    module_function :used_helper, :dead_function
  end

  BLOB = "\x03abc\x0elisted_in_blob\x02xy"
  KIND = 'interpolated'

  def fixture_run(native_call)
    w = Widget.build
    [
      w.via_super_only,
      [w].map(&:via_symbol_proc),
      native_call.call(w),
      w.respond_to?(:via_respond_to_guard),
      w.public_send("via_string_literal"),
      w.respond_to?(:"via_#{KIND}_name"),
      Helpers.used_helper,
      "#{w}"
    ]
  end
RUBY

# Not part of the closed world, but in the same VM: its calls count.
OUTSIDE = <<~'RUBY'
  OUTSIDE_ENTRY = ->(w) { w.via_outside_ruby }
RUBY

NATIVE = <<~'C'
  /* the entry point, like main_loop in app/wio/src */
  static mrb_value run(mrb_state *mrb, mrb_value top, mrb_value blk) {
    return mrb_funcall(mrb, top, "fixture_run", 1, blk);
  }
  static mrb_value call_it(mrb_state *mrb, mrb_value w) {
    return mrb_funcall(mrb, w, "via_native", 0);
  }
  void init(mrb_state *mrb, struct RClass *c) {
    mrb_define_method(mrb, c, "natively_defined_too", call_it, MRB_ARGS_NONE());
  }
C

EXPECTED_DEAD = %w[
  Base#dead_in_base Widget#natively_defined_too Widget#truly_dead Widget#dead_helper
  Widget#dead_caller Widget.singleton#dead_singleton Helpers#dead_function
].sort.freeze

# A world that dispatches a computed name the analysis has not reviewed.
UNREVIEWED = <<~'RUBY'
  class Door
    def open = 1
    def knock(name) = send(name)
  end
  Door.new.knock(ARGV.first)
RUBY

failures = []
Dir.mktmpdir do |tmp|
  world_rb = File.join(tmp, 'world.rb')
  outside_rb = File.join(tmp, 'outside.rb')
  native_c = File.join(tmp, 'native.c')
  File.write(world_rb, WORLD)
  File.write(outside_rb, OUTSIDE)
  File.write(native_c, NATIVE)

  res = WioUnreachable.analyze(world: { 'fixture' => [[world_rb, 'world.rb']] },
                               ruby: [outside_rb], native: [native_c])
  begin
    WioUnreachable.check!(res)
  rescue RuntimeError => e
    failures << "fixture world should need no review: #{e.message}"
  end
  got = res.dead.map { |d| "#{d[:owner]}##{d[:name]}" }.sort
  failures << "stripped #{(got - EXPECTED_DEAD).join(', ')}, which is reachable" unless (got - EXPECTED_DEAD).empty?
  failures << "kept #{(EXPECTED_DEAD - got).join(', ')}, which is unreachable" unless (EXPECTED_DEAD - got).empty?

  by_owner = WioUnreachable.by_owner(res.dead)
  stripped = strip_defs_from_source(WORLD, by_owner, world_rb, list_names_by_owner: by_owner,
                                                               visibility_mids: UNREACHABLE_LIST_MIDS)
  stripped_rb = File.join(tmp, 'stripped.rb')
  File.write(stripped_rb, stripped)
  # Run the stripped world: loading it runs the shrunk visibility lists, and
  # fixture_run reaches every kept method the way the analysis saw it reached.
  runner = <<~RUBY
    load #{stripped_rb.dump}
    load #{outside_rb.dump}
    out = fixture_run(->(w) { w.via_native })
    out << OUTSIDE_ENTRY.call(Widget.new(:x)) << Widget.new(:y).send(:via_respond_to_guard)
    out << (Widget.private_method_defined?(:private_helper) ? :private : :public)
    out << Widget.new(:z).listed_in_blob
    p out
    %i[truly_dead dead_helper dead_caller natively_defined_too].each do |m|
      raise "\#{m} survived the strip" if Widget.method_defined?(m) || Widget.private_method_defined?(m)
    end
  RUBY
  out, err, st = Open3.capture3(RbConfig.ruby, '-e', runner)
  expected = '[[:base_super, :widget], [:sym_proc], [:native, :helper], true, :string, true, :used, "Widget(built)", ' \
             ':outside, :guard, :private, :blob]'
  failures << "stripped fixture failed to run: #{err.lines.first(3).join}" unless st.success?
  failures << "stripped fixture ran wrong: #{out.strip}" if st.success? && out.strip != expected

  File.write(world_rb, UNREVIEWED)
  res = WioUnreachable.analyze(world: { 'fixture' => [[world_rb, 'world.rb']] }, ruby: [], native: [])
  begin
    WioUnreachable.check!(res)
    failures << 'an unreviewed computed send passed the analysis'
  rescue RuntimeError => e
    failures << "unexpected review failure: #{e.message}" unless e.message.include?('send(name)')
  end
end

if failures.empty?
  puts "wio unreachable-methods check: PASS (#{EXPECTED_DEAD.size} unreachable fixture defs, " \
       'every reachable one kept and run)'
else
  failures.each { |f| warn "  FAIL #{f}" }
  warn 'wio unreachable-methods check: FAIL'
  exit 1
end
