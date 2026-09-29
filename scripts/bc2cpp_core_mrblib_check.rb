#!/usr/bin/env ruby
# encoding: UTF-8
#
# Checks for the compiled core mrblib (docs/adr/0264): mruby's own Ruby compiled by
# mruby-core-compiled next to the three engine gems.
#
# Static (needs MRBC only):
#   - every core class that core sources define methods on is a BC2CPP_CORE_OWNERS entry,
#     and no entry is stale;
#   - every core-source method the four compiled gems emit is emitted by exactly one gem
#     (no duplicate `_impl`), and only by mruby-core-compiled;
#   - none of them touches a block or the Fiber class (a `Fiber.yield` inside a block
#     cannot cross a compiled frame), and none comes from mruby-enumerator;
#   - mruby-rpgxp/rpgvx/wolf/mvjs, which load after mruby-core-compiled in desktop builds
#     and are not part of its world, define none of the compiled (owner, name) pairs;
#   - a hot-only build (its world holds no core Ruby) emits no core method;
#   - core_refused.txt names nothing that no longer exists.
#
# Runtime (needs BC2CPP_MRUBY_CORE, a host mruby core directory with lib/libmruby_core.a):
#   the compiled bodies answer exactly what the interpreter's bytecode answers, on edge
#   cases (0, negative zero, NaN, infinities, nil, bigint and non-numeric operands, empty and
#   endless ranges, wrong argument counts and types), through the registered entry points
#   and through direct calls from compiled callers.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp_core_mrblib_check.rb

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'
require_relative '../tools/bc2cpp/compiled_gems'
require_relative '../tools/bc2cpp/never_called_registrations'

ROOT = File.expand_path('..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC_ENV = ENV['MRBC'] || 'mrbc'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

ALL_CORE_GEMS = BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS

# The registry of `files` compiled as one world (what bc2cpp.rb sees), with irep labels.
def world_registry(files)
  ireps, root = Dir.mktmpdir { |dir| compile_ireps(files, 'core_check', dir) }
  registry, = build_registry(ireps, root)
  [registry, ireps]
end

def core_defs(registry, ireps)
  registry.values.flatten.select { |d| d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
end

puts 'core mrblib: static invariants'
full_world = core_compiled_mrblib_srcs(ROOT, ALL_CORE_GEMS)
registry, ireps = world_registry(full_world)
owners = registry.values.flatten.select { |d| d.irep && CoreDefs.core_source?(ireps.fetch(d.irep).file) }
                 .map(&:owner).to_set
check.call("BC2CPP_CORE_OWNERS lists every class core sources define methods on (missing: #{(owners - BC2CPP_CORE_OWNERS).to_a.sort.join(', ')})",
           (owners - BC2CPP_CORE_OWNERS).empty?)
check.call("BC2CPP_CORE_OWNERS has no stale entry (#{(BC2CPP_CORE_OWNERS - owners.to_a).join(', ')})",
           (BC2CPP_CORE_OWNERS - owners.to_a).empty?)

# One run per compiled gem, exactly as its mrbgem.rake performs it.
runs = BC2CPP_COMPILED_GEMS.keys.map do |gem_name|
  Thread.new do
    out, err = NeverCalledRegistrations.run_bc2cpp_full(gem_name, ROOT, MRBC_ENV)
    [gem_name, out, err]
  end
end.map(&:value)

impl_owner = {}
duplicates = []
core_keys = Set.new
runs.each do |gem_name, out, err|
  out.scan(/^mrb_value (\S+_impl)\(mrb_state\* M/) do |(impl)|
    duplicates << "#{impl} (#{impl_owner[impl]} and #{gem_name})" if impl_owner.key?(impl)
    impl_owner[impl] = gem_name
  end
  section = err[/== core-source compiled entry points \(\d+\) ==\n(.*?)(?=\n==|\z)/m, 1].to_s
  keys = section.lines.map(&:strip).reject(&:empty?)
  if gem_name == 'mruby-core-compiled'
    core_keys.merge(keys)
  else
    check.call("#{gem_name} emits no core-source method (#{keys.first(3).join(', ')})", keys.empty?)
  end
end
check.call("no `_impl` is emitted by two compiled gems (#{duplicates.first(3).join('; ')})", duplicates.empty?)
check.call('mruby-core-compiled compiles a non-empty set of core methods', !core_keys.empty?)
puts "  (#{core_keys.size} core-source methods compiled)"

# Engine definitions that share an owner with core (Array, StringIO) stay with their gem.
rgss = runs.find { |name, _, _| name == 'mruby-rgss-compiled' }
check.call('Array#include? (mruby-rgss) is emitted by mruby-rgss-compiled, not the core gem',
           rgss[1].include?('Array_include$3f_impl(mrb_state* M') && !core_keys.include?('Array#include?'))

# No compiled core body may sit on the C stack while a block runs.
compiled_defs = core_defs(registry, ireps).select { |d| core_keys.include?("#{d.owner}##{d.name}") }
unsafe = compiled_defs.select do |d|
  irep = ireps.fetch(d.irep)
  CoreDefs.touches_block?(irep, ireps) || CoreDefs.references_fiber?(irep, ireps) || CoreDefs.fiber_gem?(irep.file)
end
check.call("no compiled core method touches a block, the Fiber class or mruby-enumerator (#{unsafe.map { |d| "#{d.owner}##{d.name}" }.first(3).join(', ')})",
           unsafe.empty?)

# Open-world gems load after the compiled core and are not in its world: they must not redefine a compiled
# method, and (a compiled core name with no native definition is a static call target) must not define the
# same name on any class either.
open_world_defs = Hash.new { |h, k| h[k] = [] }
%w[mruby-rpgxp mruby-rpgvx mruby-wolf mruby-mvjs].each do |gem_name|
  files = Dir[File.join(ROOT, gem_name, 'mrblib/**/*.rb')].sort
  next if files.empty?

  gem_registry, gem_ireps = world_registry(files)
  gem_registry.values.flatten.each do |d|
    next unless d.irep && !CoreDefs.core_source?(gem_ireps.fetch(d.irep).file)

    open_world_defs["#{d.owner}##{d.name}"] << gem_name
    open_world_defs["##{d.name}"] << gem_name
  end
end
# Only a registry definition (no HIDDEN entry: a name natives share) is a static call target.
hidden = runs.find { |name, _, _| name == 'mruby-core-compiled' }[2].scan(/^  HIDDEN (\S+)/).flatten.to_set
clash = core_keys.select do |k|
  open_world_defs.key?(k) || (!hidden.include?(k) && open_world_defs.key?("##{k.split('#', 2).last}"))
end
check.call("no open-world gem defines a compiled core method's name (#{clash.first(3).join(', ')})", clash.empty?)

# A hot-only build's world has no core Ruby, so it compiles none.
hot_world = closed_world_mrblib_srcs(ROOT, core_gems: nil)
check.call('a hot-only world names no core mrblib file', hot_world.none? { |f| CoreDefs.core_source?(f) })

# Refused entries are live.
core_run_err = runs.find { |name, _, _| name == 'mruby-core-compiled' }[2]
stale = core_run_err.scan(/^  STALE (\S+)/).flatten
check.call("core_refused.txt has no stale entry (#{stale.join(', ')})", stale.empty?)

# ---------------------------------------------------------------------------------------
# Runtime: interpreted bytecode vs compiled bodies.
# ---------------------------------------------------------------------------------------
CASES = <<~'RUBY'
  class CoreProbe
    def pos(x); x.positive?; end
    def neg(x); x.negative?; end
    def nz(x); x.nonzero?; end
    def isint(x); x.integer?; end
    def bits(a, m); [a.allbits?(m), a.anybits?(m), a.nobits?(m)]; end
    def cdiv(a, b); a.ceildiv(b); end
    def btw(a, lo, hi); a.between?(lo, hi); end
    def ovl(a, b); a.overlap?(b); end
    def nxt(a); a.next; end
    def signs(a); [a.positive?, a.negative?, a.zero?]; end
    def chained(a); a.positive? && !a.negative?; end
  end

  class Money
    include Comparable
    attr_reader :v
    def initialize(v); @v = v; end
    def <=>(o); o.is_a?(Money) ? @v <=> o.v : nil; end
  end

  class Cell < Numeric
    def initialize(v); @v = v; end
    def <=>(o); @v <=> (o.is_a?(Cell) ? o.v : o); end
    def v; @v; end
    def coerce(o); [Cell.new(o), self]; end
    def ==(o); @v == (o.is_a?(Cell) ? o.v : o); end
    def >(o); @v > (o.is_a?(Cell) ? o.v : o); end
    def <(o); @v < (o.is_a?(Cell) ? o.v : o); end
  end

  BIG = 2**40
  # The largest power of two a 64-bit mrb_int holds; a gem-free core has no bigint to go past it.
  HUGE = 2**62
  P = CoreProbe.new

  NUMS = [0, 1, -1, 7, -7, BIG, -BIG, HUGE, -HUGE, 0.0, -0.0, 0.5, -0.5, 1e300, -1e300,
          Float::INFINITY, -Float::INFINITY, Float::NAN, nil, true, 'x', :s, [], {}, Object.new, Cell.new(3), Cell.new(-3), Cell.new(0)]

  def probe
    out = []
    NUMS.each_with_index do |x, i|
      %i[positive? negative? nonzero? integer? zero? abs next -@ +@].each do |m|
        out << ["#{m} #{i}", -> { x.send(m) }]
      end
      out << ["probe.pos #{i}", -> { P.pos(x) }] if x.is_a?(Numeric)
      out << ["probe.neg #{i}", -> { P.neg(x) }] if x.is_a?(Numeric)
      out << ["probe.nz #{i}", -> { P.nz(x) }] if x.is_a?(Numeric)
      out << ["probe.isint #{i}", -> { P.isint(x) }] if x.is_a?(Numeric)
      out << ["probe.signs #{i}", -> { P.signs(x) }] if x.is_a?(Numeric)
      out << ["probe.chained #{i}", -> { P.chained(x) }] if x.is_a?(Numeric)
    end
    ints = [0, 1, -1, 5, 6, 10, 12, -12, 255, -256, BIG, HUGE, 1.0, nil, 'a']
    ints.each_with_index do |a, i|
      ints.each_with_index do |b, j|
        %i[allbits? anybits? nobits? ceildiv].each do |m|
          out << ["#{m} #{i} #{j}", -> { a.send(m, b) }]
        end
        out << ["probe.bits #{i} #{j}", -> { P.bits(a, b) }] if a.is_a?(Integer)
        out << ["probe.cdiv #{i} #{j}", -> { P.cdiv(a, b) }] if a.is_a?(Integer)
      end
    end
    out << ['allbits? no args', -> { 1.allbits? }]
    out << ['allbits? 2 args', -> { 1.allbits?(1, 2) }]
    out << ['ceildiv zero', -> { 1.ceildiv(0) }]
    out << ['ceildiv min', -> { (-2**31).ceildiv(-1) }]
    out << ['ceildiv overflow', -> { [(-HUGE).ceildiv(-1), (HUGE * 2).ceildiv(3)] }]

    ranks = [1, 5, 10, 1.5, 5.5, 'b', 'a', :a, nil, Money.new(3), Money.new(9), Money.new(5)]
    ranks.each_with_index do |a, i|
      ranks.each_with_index do |lo, j|
        [1, 5, 10, 'z', Money.new(7)].each_with_index do |hi, k|
          out << ["between? #{i} #{j} #{k}", -> { a.between?(lo, hi) }]
          out << ["probe.btw #{i} #{j} #{k}", -> { P.btw(a, lo, hi) }] if a.respond_to?(:between?)
        end
      end
    end
    out << ['between? arity', -> { 1.between?(1) }]
    out << ['Money cmp', -> { [Money.new(1) < Money.new(2), Money.new(2) >= Money.new(2), Money.new(1) == Money.new(1), Money.new(1) == 1] }]
    out << ['Money cmp fail', -> { Money.new(1) < 3 }]
    out << ['Money ge fail', -> { Money.new(1) >= 'x' }]

    ranges = [1..5, 1...5, 5..1, 1..1, 1...1, 4..6, 7..9, 1.., ..5, (1..), 1.0..2.5, 'a'..'e', 'c'..'z', nil..nil, 0...0, -3..3, 2..2, 5...6]
    ranges.each_with_index do |a, i|
      ranges.each_with_index do |b, j|
        out << ["overlap? #{i} #{j}", -> { a.overlap?(b) }]
        out << ["probe.ovl #{i} #{j}", -> { P.ovl(a, b) }]
      end
      out << ["overlap? nonrange #{i}", -> { a.overlap?(3) }]
      out << ["last #{i}", -> { a.last }]
      out << ["last 0 #{i}", -> { a.last(0) }]
      out << ["last 2 #{i}", -> { a.last(2) }]
      out << ["last -1 #{i}", -> { a.last(-1) }]
      out << ["last 1,2 #{i}", -> { a.last(1, 2) }]
      out << ["last x #{i}", -> { a.last('x') }]
      out << ["hash #{i}", -> { [a.hash == a.dup.hash, a.hash == (a.first..a.last).hash] }]
    end

    nest = { a: [1, { b: [10, 20, { c: 3 }] }], 'k' => nil, 2 => 5 }
    out << ['Hash#dig', -> { [nest.dig(:a, 1, :b, 2, :c), nest.dig(:zz), nest.dig('k', :x), nest.dig(:a, 0)] }]
    out << ['Hash#dig bad', -> { nest.dig(2, 1) }]
    out << ['Hash#dig none', -> { nest.dig }]
    out << ['Array#dig', -> { [[1, [2, [3]]].dig(1, 1, 0), [].dig(0), [nil].dig(0, 1), [1].dig(5)] }]
    out << ['Array#dig bad', -> { [1, 2].dig(0, 1) }]
    out << ['Array#dig none', -> { [1].dig }]
    out << ['Array#dig type', -> { [1].dig('x') }]
    out << ['Hash#deconstruct_keys', -> { [nest.deconstruct_keys(nil).equal?(nest), { a: 1 }.deconstruct_keys([:a])] }]
    out << ['Array#deconstruct', -> { a = [1, 2]; a.deconstruct.equal?(a) }]

    hs = [{}, { a: nil }, { a: 1, b: nil, c: 2 }, { nil => nil }, { 1 => [nil], 2 => nil }, Hash.new(7).merge(a: nil, b: 1)]
    hs.each_with_index do |h, i|
      out << ["compact #{i}", -> { r = h.compact; [r, r.equal?(h), r.size] }]
      out << ["compact! #{i}", -> { c = h.dup; [c.compact!, c] }]
      out << ["flatten #{i}", -> { h.flatten }]
      out << ["flatten 2 #{i}", -> { h.flatten(2) }]
      out << ["flatten 0 #{i}", -> { h.flatten(0) }]
      out << ["flatten -1 #{i}", -> { h.flatten(-1) }]
      out << ["flatten x #{i}", -> { h.flatten('x') }]
      out << ["to_h #{i}", -> { r = h.to_h; [r, r.equal?(h)] }]
    end
    out << ['compact default', -> { h = Hash.new(5); h[:a] = nil; h.compact[:zz] }]
    out << ['compact! frozen', -> { { a: nil }.freeze.compact! }]
    out << ['compact frozen', -> { { a: nil }.freeze.compact }]

    out << ['`', -> { `echo` }]
    out << ['!~', -> { ['abc' !~ 'b', 1 !~ 1, nil !~ nil] }]
    out
  end

  def run_cases
    probe.map do |name, blk|
      r = begin
        blk.call.inspect
      rescue Exception => e
        "#{e.class}: #{e.message}"
      end
      "#{name}: #{r}"
    end
  end
RUBY

core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end

puts 'core mrblib: compiled bodies vs interpreter'
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP runtime check: set BC2CPP_MRUBY_CORE to a host mruby core directory'
else
  # BC2CPP_CHECK_KEEP_DIR: leave the probe's sources and binary there for debugging.
  runtime_dir = lambda do |&block|
    keep = ENV['BC2CPP_CHECK_KEEP_DIR']
    keep ? block.call(FileUtils.mkdir_p(keep).first) : Dir.mktmpdir(&block)
  end
  runtime_dir.call do |dir|
    # Only the core files a gem-free mruby core can define (no io, dir, stringio, sprintf, struct, ...).
    core_files = core_compiled_mrblib_srcs(ROOT, %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-numeric-ext
                                                     mruby-range-ext mruby-string-ext])
    probe = File.join(dir, 'core_probe.rb')
    File.write(probe, CASES)
    generated = File.join(dir, 'core_probe_gen.cpp')
    only = (BC2CPP_CORE_OWNERS + %w[CoreProbe]).join(',')
    # NATIVE_SRCS is what makes `flatten` POLY here: without it Hash#flatten (Ruby) looks like the
    # name's only definition, and its body's `to_a.flatten` binds back to itself.
    native_srcs = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
    env = { 'MRBC' => MRBC_ENV, 'OUT_SYMBOL' => 'core_probe', 'OUT_DIR' => dir, 'ONLY_OWNERS' => only,
            'NATIVE_SRCS' => Shellwords.join(native_srcs), 'SKIP_UNSUPPORTED' => '1' }
    _out, err, status = Open3.capture3(env, "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} " \
                                            "#{[*core_files, probe].map(&:shellescape).join(' ')} > #{generated.shellescape}")
    abort "bc2cpp.rb failed:\n#{err[-3000..]}" unless status.success?
    compiled = err[/== core-source compiled entry points \((\d+)\)/, 1].to_i
    check.call("the probe world compiles core methods (#{compiled})", compiled.positive?)
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/array.h>
      #include <mruby/irep.h>
      #include <mruby/string.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <string>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      #include "core_probe_gen.cpp"
      // A registered aspec makes the VM reject a bad argument count before the wrapper runs, and it
      // spells the range "expected 1+" / "expected 1..2", where OP_ENTER's own check of the bytecode
      // said "expected 1" (vm.c argnum_error). The class and the counts agree; only that suffix differs.
      static std::string normalize(const std::string& s) {
        size_t at = s.find("expected ");
        if (s.find("wrong number of arguments") == std::string::npos || at == std::string::npos) return s;
        size_t end = at + 9;
        while (end < s.size() && s[end] >= '0' && s[end] <= '9') ++end;
        size_t stop = end;
        if (stop < s.size() && s[stop] == '+') ++stop;
        else if (s.compare(stop, 2, "..") == 0) { stop += 2; while (stop < s.size() && s[stop] >= '0' && s[stop] <= '9') ++stop; }
        return s.substr(0, end) + s.substr(stop);
      }
      static std::vector<std::string> run(mrb_state* M) {
        mrb_value r = mrb_funcall(M, mrb_top_self(M), "run_cases", 0);
        std::vector<std::string> out;
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return out; }
        for (mrb_int i = 0; i < RARRAY_LEN(r); ++i) {
          mrb_value s = mrb_ary_ref(M, r, i);
          out.emplace_back(RSTRING_PTR(s), RSTRING_LEN(s));
        }
        return out;
      }
      int main(int, char** argv) {
        mrb_state* M = mrb_open_core();
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        std::vector<std::string> interpreted = run(M);
        bc2cpp_set_instance_tts(M);
        bc2cpp_register_owner_methods(M);
        std::vector<std::string> compiled = run(M);
        if (interpreted.empty() || interpreted.size() != compiled.size()) {
          std::printf("  FAIL result lists differ in size: %zu vs %zu\\n", interpreted.size(), compiled.size());
          return 1;
        }
        int wrong = 0;
        for (size_t i = 0; i < interpreted.size(); ++i) {
          if (normalize(interpreted[i]) != normalize(compiled[i])) {
            if (++wrong <= 20) std::printf("  WRONG\\n    interpreted: %s\\n    compiled:    %s\\n", interpreted[i].c_str(), compiled[i].c_str());
          }
        }
        std::printf("  %zu cases, %d differ\\n", interpreted.size(), wrong);
        mrb_close(M);
        return wrong ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'core_probe')
    built = system('g++', '-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/include",
                   File.join(dir, 'main.cpp'), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the probe compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'core_probe.mrb')], err: %i[child out], &:read)
      puts output
      puts "  (exit status #{$?.exitstatus || $?.termsig})" unless $?.success?
      check.call('compiled core methods answer exactly what the interpreter answers', $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp core mrblib check: PASS'
else
  warn "bc2cpp core mrblib check: #{failures.size} failure(s)"
  exit 1
end
