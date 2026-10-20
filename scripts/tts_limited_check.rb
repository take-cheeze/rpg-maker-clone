#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0417: RGSS::Tts (Zundamon/VOICEVOX narration, ADR 0046) exists only where
# a backend can: the desktop "host" build. Every limited build (wio, maix, psp,
# emscripten, android) must carry no RGSS::Tts native registration and no Ruby
# naming it, and the desktop build must keep both, behaving as before.
#
#   ruby scripts/tts_limited_check.rb                 # pure Ruby, no submodules
#   MRBC=path/to/mrbc ruby scripts/tts_limited_check.rb --bc2cpp
#
# The default run proves, from the real mrbgem.rake files and sources:
#   1. tools/rgss_tts_config.rb: only `host` can have a backend.
#   2. mruby-rgss/mrbgem.rake: tts.cxx is an object of the host build only, the
#      empty tts_off.cxx of every other; lib.cxx is untouched (its digest is
#      pinned by bc2cpp).
#   3. mruby-rpg2k/mrbgem.rake: the host build ships scene/map_tts.rb, every
#      other build mrblib_limited/map_tts_off.rb, and no Ruby a limited build
#      compiles contains `Tts`.
#   4. The bc2cpp closed-world source sets (compiled_gems.rb) agree with that
#      per build.
#   5. Scene::Map#speak_message: where Tts exists it behaves exactly as the
#      pre-ADR-0417 method (reference copy below); in a limited build it is a
#      private no-op that never touches RGSS::Tts, even with one defined.
#
# --bc2cpp (nightly, needs a host mrbc, minutes): runs bc2cpp over the wio
# closed world for mruby-rpg2k-compiled and fails if the generated C++ names
# Tts or sends `speak_message`'s calls by name.

require 'open3'
require 'ripper'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
require_relative '../tools/rgss_tts_config'
require_relative '../tools/bc2cpp/compiled_gems'

$failures = 0
def check(name, ok, detail = nil)
  if ok
    puts "ok   #{name}"
  else
    $failures += 1
    puts "FAIL #{name}#{detail ? " -- #{detail}" : ''}"
  end
end

LIMITED = %w[wio maix psp emscripten android].freeze
BUILDS = (['host'] + LIMITED).freeze

# -- 1. the predicate -----------------------------------------------------------

BUILDS.each do |b|
  check "backend_possible?(#{b}) == #{b == 'host'}", RgssTtsConfig.backend_possible?(b) == (b == 'host')
end
check 'optcarrot-probe has no backend', !RgssTtsConfig.backend_possible?('optcarrot-probe')

# -- 2/3. the real mrbgem.rake files, evaluated against a recording spec ----------

# Just enough of MRuby::Gem::Specification for the two rake files: the attributes
# they filter (rbfiles, objs, cxx.defines); anything else is swallowed. Same idea
# as scripts/wio/unreachable_methods.rb's SpecProbe.
class SpecProbe
  class Sink < BasicObject
    def method_missing(*) = self
    def respond_to_missing?(*) = true
    def <<(_other) = self
  end

  Build = Struct.new(:name)
  class Compiler
    attr_reader :defines

    def initialize = @defines = []
    def method_missing(*) = Sink.new
    def respond_to_missing?(*) = true
  end
  attr_reader :dir, :build_dir, :rbfiles, :objs, :cxx, :build

  def initialize(dir, build_name)
    @dir = dir
    @build_dir = "/nonexistent/build/#{build_name}/#{File.basename(dir)}"
    @build = Build.new(build_name)
    @cxx = Compiler.new
    @rbfiles = Dir.glob("#{dir}/mrblib/**/*.rb").sort
    @objs = Dir.glob("#{dir}/src/*.{c,cxx}").map { |f| objfile("#{build_dir}/src/#{File.basename(f, '.*')}") }
  end

  def objfile(path) = "#{path}.o"
  def spec = self
  def rbfiles=(files)
    @rbfiles = files
  end

  def method_missing(*) = Sink.new
  def respond_to_missing?(*) = true
end

def probe(gem_name, build_name)
  gem_dir = File.join(ROOT, gem_name)
  spec = SpecProbe.new(gem_dir, build_name)
  spec_class = Class.new { define_singleton_method(:new) { |_name, &blk| spec.instance_exec(spec, &blk) } }
  mruby = Module.new
  mruby.const_set(:Gem, Module.new)
  mruby::Gem.const_set(:Specification, spec_class)
  sandbox = Module.new
  sandbox.const_set(:MRuby, mruby)
  # The ENV the cross builds set must not leak into a name-keyed decision.
  sandbox.module_eval(File.read("#{gem_dir}/mrbgem.rake", encoding: 'UTF-8'), "#{gem_dir}/mrbgem.rake")
  spec
end

BUILDS.each do |b|
  host = b == 'host'
  rgss = probe('mruby-rgss', b)
  check "mruby-rgss #{b}: tts.cxx is #{host ? '' : 'not '}an object", rgss.objs.any? { |o| o.end_with?('/src/tts.o') } == host
  check "mruby-rgss #{b}: tts_off.cxx is #{host ? 'not ' : ''}an object", rgss.objs.any? { |o| o.end_with?('/src/tts_off.o') } == !host

  rpg2k = probe('mruby-rpg2k', b)
  names = rpg2k.rbfiles.map { |f| f.delete_prefix("#{File.join(ROOT, 'mruby-rpg2k')}/") }
  check "mruby-rpg2k #{b}: map_tts.rb is #{host ? '' : 'not '}shipped", names.include?('mrblib/scene/map_tts.rb') == host
  check "mruby-rpg2k #{b}: map_tts_off.rb is #{host ? 'not ' : ''}shipped", names.include?('mrblib_limited/map_tts_off.rb') == !host
  check "mruby-rpg2k #{b}: the stand-in loads after map.rb",
        host || names.index('mrblib_limited/map_tts_off.rb') > names.index('mrblib/scene/map.rb')

  ruby_files = rpg2k.rbfiles + rgss.rbfiles
  named = ruby_files.select { |f| Ripper.lex(File.read(f, encoding: 'UTF-8')).any? { |(_, type, tok, _)| type == :on_const && tok == 'Tts' } }
                    .map { |f| File.basename(f) }
  check "#{b}: Ruby code naming the Tts constant is #{host ? 'exactly map_tts.rb' : 'absent'}", named == (host ? ['map_tts.rb'] : [])
end

# lib.cxx must stay byte-identical in this respect: it calls rgss_tts_define
# unconditionally (tools/bc2cpp/native_class_results.rb pins its digest), and
# tts_off.cxx's empty definition is what keeps RGSS::Tts unregistered.
lib_src = File.read(File.join(ROOT, 'mruby-rgss/src/lib.cxx'), encoding: 'UTF-8')
off_cxx = File.read(File.join(ROOT, RgssTtsConfig::RGSS_TTS_OFF_CXX), encoding: 'UTF-8')
tts_cxx = File.read(File.join(ROOT, RgssTtsConfig::RGSS_TTS_CXX), encoding: 'UTF-8')
check 'lib.cxx calls rgss_tts_define once, unconditionally', lib_src.scan('rgss_tts_define(M, m);').size == 1 && !lib_src.include?('RGSS_NO_TTS')
check 'tts_off.cxx defines rgss_tts_define and registers nothing',
      off_cxx.include?('void rgss_tts_define(mrb_state* M, RClass* rgss)') && off_cxx !~ /mrb_define|define_module|"Tts"/
check 'tts.cxx is the one that registers RGSS::Tts', tts_cxx.include?('mrb_define_module_under(M, rgss, "Tts")')

# -- 4. the bc2cpp world agrees with each build -------------------------------------

def tail_names(srcs) = srcs.map { |s| s.sub(%r{\A.*/(?=mruby-)}, '') }

BUILDS.each do |b|
  host = b == 'host'
  world = tail_names(closed_world_mrblib_srcs(ROOT, tts: RgssTtsConfig.backend_possible?(b)))
  check "closed world #{b}: map_tts.rb #{host ? 'in' : 'out'}", world.include?('mruby-rpg2k/mrblib/scene/map_tts.rb') == host
  check "closed world #{b}: map_tts_off.rb #{host ? 'out' : 'in'}", world.include?('mruby-rpg2k/mrblib_limited/map_tts_off.rb') == !host
  natives = bc2cpp_rgss_native_srcs(ROOT, b).map { |s| File.basename(s) }
  check "native sources #{b}: tts.cxx #{host ? 'in' : 'out'}", natives.include?('tts.cxx') == host
  outside_native, = bc2cpp_closed_world_outside_srcs(b, { 'mruby-rgss' => File.join(ROOT, 'mruby-rgss') }, ROOT)
  check "outside sources #{b}: tts.cxx #{host ? 'in' : 'out'}", outside_native.any? { |p| p.end_with?('/mruby-rgss/src/tts.cxx') } == host
end
canonical = tail_names(closed_world_mrblib_srcs(ROOT))
check 'canonical (wio) world has no map_tts.rb', !canonical.include?('mruby-rpg2k/mrblib/scene/map_tts.rb')
check 'the stand-in sorts after map.rb in the world',
      canonical.index('mruby-rpg2k/mrblib_limited/map_tts_off.rb') > canonical.index('mruby-rpg2k/mrblib/scene/map.rb')
check 'prerequisites name both files', (tail_names(bc2cpp_closed_world_prerequisites(ROOT)) &
  %w[mruby-rpg2k/mrblib/scene/map_tts.rb mruby-rpg2k/mrblib_limited/map_tts_off.rb]).size == 2

# -- 5. speak_message ---------------------------------------------------------------

map_rb = File.read(File.join(ROOT, 'mruby-rpg2k/mrblib/scene/map.rb'), encoding: 'UTF-8')
check 'map.rb no longer defines or names RGSS::Tts', !map_rb.match?(/def speak_message|RGSS::Tts/)
check 'map.rb still calls speak_message at both Show Text/Choices sites', map_rb.scan(/^\s*speak_message\(/).size == 2

# Reference: the method exactly as it was before ADR 0417 (map.rb).
REFERENCE = <<~'RUBY'
  class RPG2k
    module Scene
      class Map < Base
        private

        def speak_message(plain_lines)
          return unless RGSS::Tts.available?
          text = plain_lines.join("\n")
          RGSS::Tts.speak(text) unless text.strip.empty?
        end
      end
    end
  end
RUBY

# Evaluates each source in a fresh namespace holding a stand-in RPG2k::Scene::Map
# (Base is empty) and, when `with_tts`, a recording RGSS::Tts. Returns
# [texts spoken, return value, whether #speak_message is private].
def speak_run(sources:, with_tts: true, available: true, lines:)
  calls = []
  ns = Module.new
  ns.module_eval('class RPG2k; module Scene; class Base; end; class Map < Base; end; end; end', 'speak_ns.rb')
  if with_tts
    tts = Module.new
    tts.define_singleton_method(:available?) { available }
    tts.define_singleton_method(:speak) { |t| calls << t; nil }
    rgss = Module.new
    rgss.const_set(:Tts, tts)
    ns.const_set(:RGSS, rgss)
  end
  sources.each { |text| ns.module_eval(text, 'speak_variant.rb') }
  map = ns::RPG2k::Scene::Map
  [calls, map.allocate.send(:speak_message, lines), map.private_method_defined?(:speak_message)]
end

tts_src = File.read(File.join(ROOT, 'mruby-rpg2k/mrblib/scene/map_tts.rb'), encoding: 'UTF-8')
off_src = File.read(File.join(ROOT, 'mruby-rpg2k/mrblib_limited/map_tts_off.rb'), encoding: 'UTF-8')
[
  [%w[hello world], true], [['  '], true], [[], true], [['a'], false], [["こんにちは", "\n", "x"], true]
].each do |lines, available|
  want = speak_run(sources: [REFERENCE], available: available, lines: lines)
  got = speak_run(sources: [tts_src], available: available, lines: lines)
  check "desktop speak_message(#{lines.inspect}, available=#{available}) == pre-ADR-0417", want == got, "#{want.inspect} vs #{got.inspect}"
  limited = speak_run(sources: [off_src], available: available, lines: lines)
  check "limited speak_message(#{lines.inspect}) speaks nothing", limited == [[], nil, true], limited.inspect
end
check 'limited speak_message needs no RGSS::Tts at all',
      speak_run(sources: [off_src], with_tts: false, lines: %w[x]) == [[], nil, true]
check 'desktop speak_message really speaks', speak_run(sources: [tts_src], lines: %w[a b])[0] == ["a\nb"]

# -- --bc2cpp ------------------------------------------------------------------------

if ARGV.include?('--bc2cpp')
  mrbc = ENV.fetch('MRBC') { abort 'MRBC=path/to/mrbc is required for --bc2cpp' }
  require_relative '../tools/bc2cpp/nomethod_reviewed_probe'
  out, err, status = NomethodReviewedProbe.run('mruby-rpg2k-compiled', ROOT, mrbc)
  check 'bc2cpp (closed world, mruby-rpg2k-compiled) runs', status.success?, err[-500..]
  check 'bc2cpp output never names Tts', !out.match?(/Tts|tts_(available|speak|stop)/), out.lines.grep(/Tts|tts_/).first(3).join
  puts "bc2cpp_send(M sites: #{out.scan('bc2cpp_send(M').size}"
end

puts($failures.zero? ? 'tts limited check: all checks passed' : "tts limited check: #{$failures} FAILED")
exit($failures.zero? ? 0 : 1)
