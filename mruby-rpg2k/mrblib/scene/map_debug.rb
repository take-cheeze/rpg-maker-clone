# The entry points of the developer tools (Scene::DebugMenu, Scene::MapViewer,
# Scene::ChipsetEditor): F9 on the field map and the --rpg2k_map_editor /
# --rpg2k_chipset_editor launch flags. A build without the tools (wio, see
# tools/rpg2k_debug_tools_config.rb) compiles mrblib_limited/map_debug_off.rb in
# this file's place, so nothing there names them. Loaded after map.rb (sorted).
class RPG2k
  # --rpg2k_map_editor: push Scene::MapViewer straight into Edit mode on top
  # of the just-built map scene, the same scene F9's Map page would push, just
  # skipping the menu navigation to get there.
  def open_map_editor(state)
    push Scene::MapViewer.new(self, state, start_mode: :edit, quit_on_close: true)
  rescue StandardError => e
    $stderr.puts "[RPG2k] --rpg2k_map_editor failed to open: #{e.message}"
  end

  # --rpg2k_chipset_editor: push Scene::ChipsetEditor for the starting map's
  # chipset, the same scene F9's Chipset page would push.
  def open_chipset_editor(state)
    push Scene::ChipsetEditor.new(self, state, quit_on_close: true)
  rescue StandardError => e
    $stderr.puts "[RPG2k] --rpg2k_chipset_editor failed to open: #{e.message}"
  end

  module Scene
    class Map < Base
      # RPG_RT's F9 debug menu: a switch/variable viewer-editor, reachable from
      # the field map only (not while an event holds the interpreter) and only
      # during Test Play -- a released game (RPG2k#test_play false) never sees
      # F9 open anything, same as every other test-play-gated tool (see
      # changelog.d/test-play-gated-debug-tooling.added.md). A battle does NOT
      # block it, per community RPG_RT trivia (@2000_battle_bot /
      # デフォ戦bot): "テストプレイ中にＦ９キーを押せば スイッチ・変数の値を
      # 好きに変えられる。これは戦闘中でも行える。" -- so `@battle` alone is
      # excluded from the busy check here (Scene::Battle#update calls this
      # directly, see there), while every other #event_busy? condition (a
      # message window, an interpreter mid-wait) still gates the ordinary
      # field-map case exactly as before.
      def try_open_debug_menu
        return if event_busy? && @battle.nil?
        return unless @parent.test_play
        return unless Input.trigger?(Input::F9)
        # psp's rbfiles drop debug_menu.rb (mruby-rpg2k/mrbgem.rake) but keep this file: a no-op rather than a
        # NameError there.
        return unless defined?(Scene::DebugMenu)
        @parent.push Scene::DebugMenu.new(@parent, @state)
      end
    end
  end
end
