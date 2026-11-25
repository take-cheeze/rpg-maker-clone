#!/usr/bin/env ruby
# frozen_string_literal: true

# The RPG2k developer tools (Scene::DebugMenu, Scene::MapViewer,
# Scene::ChipsetEditor) are left out of the wio closed world, and nothing left
# there names them (tools/rpg2k_debug_tools_config.rb). Every other build keeps
# them, and WIO_DEBUG_SCENES=1 keeps them on wio.
#
#   ruby scripts/wio/debug_scenes_check.rb      # pure Ruby, needs 3rd/nfcxx

require 'prism'
require 'tmpdir'
ROOT = File.expand_path('../..', __dir__)
require_relative '../../tools/bc2cpp/compiled_gem_sources'
CompiledGemSources.write!(ROOT, ROOT)
require_relative '../../tools/rpg2k_debug_tools_config'
require_relative '../../tools/bc2cpp_tree'
require File.join(BC2CPP_TREE, 'tools/bc2cpp/compiled_gems')

$failures = 0
def check(name, ok, detail = nil)
  if ok
    puts "ok   #{name}"
  else
    $failures += 1
    puts "FAIL #{name}#{detail ? " -- #{detail}" : ''}"
  end
end

Cfg = Rpg2kDebugToolsConfig
OTHER_BUILDS = %w[host closed psp maix emscripten android].freeze

# -- the predicate ------------------------------------------------------------------

check 'wio leaves the tools out', !Cfg.kept?('wio', {})
check 'WIO_DEBUG_SCENES=1 keeps them on wio', Cfg.kept?('wio', { 'WIO_DEBUG_SCENES' => '1' })
check 'WIO_DEBUG_SCENES=0 does not', !Cfg.kept?('wio', { 'WIO_DEBUG_SCENES' => '0' })
OTHER_BUILDS.each { |b| check "#{b} keeps the tools", Cfg.kept?(b, {}) }

# -- the closed world each build compiles -------------------------------------------

def tail_names(srcs) = srcs.map { |s| s.sub(%r{\A.*/(?=mruby-)}, '') }

# What bc2cpp_closed_world_srcs needs of a gem spec.
Spec = Struct.new(:build)
Build = Struct.new(:name, :gems)
def build_world(name, env = {})
  saved = ENV.to_h.slice(Cfg::KEEP_ENV)
  ENV.delete(Cfg::KEEP_ENV)
  env.each { |k, v| ENV[k] = v }
  bc2cpp_closed_world_srcs(Spec.new(Build.new(name, [])), ROOT)
ensure
  ENV.delete(Cfg::KEEP_ENV)
  saved.each { |k, v| ENV[k] = v }
end

wio_paths = build_world('wio')
full_paths = build_world('closed')
wio = tail_names(wio_paths)
full = tail_names(full_paths)
Cfg::DROPPED_RBS.each do |rel|
  check "wio world leaves out #{rel}", !wio.include?(rel)
  check "closed world keeps #{rel}", full.include?(rel)
end
check 'wio world compiles the stand-in', wio.include?(Cfg::OFF_RB)
check 'the stand-in sorts after map.rb', wio.index(Cfg::OFF_RB).to_i > wio.index('mruby-rpg2k/mrblib/scene/map.rb').to_i
check 'closed world has no stand-in', !full.include?(Cfg::OFF_RB)
check 'the wio world is the closed one less the tools, plus the stand-in',
      wio.sort == (full - Cfg::DROPPED_RBS + [Cfg::OFF_RB]).sort
check 'WIO_DEBUG_SCENES=1 gives wio the closed world', build_world('wio', Cfg::KEEP_ENV => '1') == full_paths
check 'prerequisites name the stand-in', tail_names(bc2cpp_closed_world_prerequisites(ROOT)).include?(Cfg::OFF_RB)

check 'nothing in the wio world names the tools', Cfg.references(wio_paths).empty?,
      Cfg.references(wio_paths).first(5).inspect
defined_classes = wio_paths.flat_map do |path|
  found = []
  walk = lambda do |node|
    return unless node.is_a?(Prism::Node)

    found << node.constant_path.slice if node.is_a?(Prism::ClassNode) && Cfg::CLASSES.include?(node.constant_path.slice.split('::').last)
    node.compact_child_nodes.each { |c| walk.call(c) }
  end
  walk.call(Prism.parse_file(path).value)
  found
end
check 'nothing in the wio world defines them', defined_classes.empty?, defined_classes.inspect
check 'the full world names them outside the dropped files only',
      Cfg.references(full_paths)
         .map { |(path, _, _)| path.delete_prefix("#{ROOT}/") }.uniq.all? { |rel| Cfg::DROPPED_RBS.include?(rel) }

# -- the build guard ----------------------------------------------------------------

def raises?
  yield
  false
rescue RuntimeError
  true
end

check 'verify_world! accepts the wio world', !raises? { Cfg.verify_world!(wio_paths) }
Dir.mktmpdir('debug_scenes_check') do |tmp|
  planted = File.join(tmp, 'planted.rb')
  File.write(planted, "class RPG2k; def f; Scene::MapViewer.new; end; end\n")
  check 'verify_world! rejects a surviving reference', raises? { Cfg.verify_world!(wio_paths + [planted]) }
  File.write(planted, "x = defined?(DebugMenu)\n")
  check 'verify_world! rejects a defined? probe', raises? { Cfg.verify_world!(wio_paths + [planted]) }
end
check 'verify_world! rejects a dropped file', raises? { Cfg.verify_world!(wio_paths + [File.join(ROOT, Cfg::DROPPED_RBS.first)]) }

# -- the stand-in has the same entry points ----------------------------------------

def entry_points(path)
  found = []
  walk = lambda do |node, scope|
    return unless node.is_a?(Prism::Node)

    case node
    when Prism::ClassNode, Prism::ModuleNode
      scope = scope + [node.constant_path.slice]
    when Prism::DefNode
      found << ["#{scope.join('::')}##{node.name}", node.parameters&.slice]
    end
    node.compact_child_nodes.each { |c| walk.call(c, scope) }
  end
  walk.call(Prism.parse_file(path).value, [])
  found.sort
end
on = entry_points(File.join(ROOT, 'mruby-rpg2k/mrblib/scene/map_debug.rb'))
off = entry_points(File.join(ROOT, Cfg::OFF_RB))
check 'map_debug_off.rb defines exactly map_debug.rb\'s methods', on == off, "#{on.inspect} vs #{off.inspect}"

puts($failures.zero? ? 'debug scenes check: all checks passed' : "debug scenes check: #{$failures} FAILED")
exit($failures.zero? ? 0 : 1)
