# The developer tools' entry points for a build without the tools (wio, see
# tools/rpg2k_debug_tools_config.rb): the same methods as
# mrblib/scene/map_debug.rb, doing nothing, so no Ruby there names
# Scene::DebugMenu, Scene::MapViewer or Scene::ChipsetEditor. Not under mrblib/,
# so nothing that globs mrblib/**/*.rb sees both definitions.
class RPG2k
  def open_map_editor(state)
  end

  def open_chipset_editor(state)
  end

  module Scene
    class Map < Base
      def try_open_debug_menu
      end
    end
  end
end
