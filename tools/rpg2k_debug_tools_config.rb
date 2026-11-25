# frozen_string_literal: true

require 'prism'

# Which builds keep the RPG2k developer tools: the F9 debug menu
# (Scene::DebugMenu), the map viewer/editor (Scene::MapViewer) and the chipset
# editor (Scene::ChipsetEditor), plus their entry points (F9, --rpg2k_map_editor,
# --rpg2k_chipset_editor). Every build but wio keeps them. wio leaves them out of
# its closed world to save flash; WIO_DEBUG_SCENES=1 keeps them there too.
#
# The entry points live in mruby-rpg2k/mrblib/scene/map_debug.rb; a build without
# the tools compiles mruby-rpg2k/mrblib_limited/map_debug_off.rb in its place
# (bc2cpp's closed_world_mrblib_srcs swaps them, as it swaps map_tts.rb).
module Rpg2kDebugToolsConfig
  # Repo-relative mrblib files a build without the tools leaves out.
  DROPPED_RBS = %w[
    mruby-rpg2k/mrblib/scene/chipset_editor.rb
    mruby-rpg2k/mrblib/scene/debug_menu.rb
    mruby-rpg2k/mrblib/scene/map_debug.rb
    mruby-rpg2k/mrblib/scene/map_viewer.rb
  ].freeze
  # Its stand-in for scene/map_debug.rb: the same entry points, doing nothing.
  OFF_RB = 'mruby-rpg2k/mrblib_limited/map_debug_off.rb'
  # The classes the dropped files define (under RPG2k::Scene).
  CLASSES = %w[ChipsetEditor DebugMenu MapViewer].freeze
  QUALIFIED_CLASSES = CLASSES.map { |name| "RPG2k::Scene::#{name}" }.freeze
  # The builds that leave them out.
  DROPPING_BUILDS = %w[wio].freeze
  KEEP_ENV = 'WIO_DEBUG_SCENES'

  module_function

  def kept?(build_name, env = ENV)
    !DROPPING_BUILDS.include?(build_name.to_s) || env[KEEP_ENV] == '1'
  end

  # [path, line, name] of every constant reference to CLASSES in `paths`.
  def references(paths)
    paths.flat_map do |path|
      found = []
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)

        name = case node
               when Prism::ConstantReadNode, Prism::ConstantWriteNode, Prism::ConstantPathNode then node.name
               end
        found << [path, node.location.start_line, name.to_s] if name && CLASSES.include?(name.to_s)
        node.compact_child_nodes.each { |child| walk.call(child) }
      end
      result = Prism.parse_file(path)
      raise "#{path}: does not parse: #{result.errors.first.message}" unless result.errors.empty?

      walk.call(result.value)
      found
    end
  end

  # A world without the tools must not name them: a surviving reference would
  # be a NameError at run time. Raises, so the build stops.
  def verify_world!(paths)
    @verified ||= {}
    key = paths.join("\n")
    return if @verified[key]

    dropped = paths.select { |p| DROPPED_RBS.any? { |rel| p.end_with?("/#{rel}") } }
    raise "rpg2k debug tools: the world still compiles #{dropped.join(', ')}" unless dropped.empty?

    refs = references(paths)
    unless refs.empty?
      list = refs.map { |(path, line, name)| "#{path}:#{line}: #{name}" }.join("\n  ")
      raise "rpg2k debug tools: a build without them still names them (set #{KEEP_ENV}=1 to keep them):\n  #{list}"
    end
    @verified[key] = true
  end
end
