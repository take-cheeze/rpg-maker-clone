# Headless save screen from the menu: New Game, open the save scene in :save mode, confirm slot 2, then load it.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
g = RPG2k.new(['TestPlay'])
g.start_new_game
60.times { g.main_loop }
state = g.instance_variable_get(:@scenes).last.instance_variable_get(:@state)
g.push RPG2k::Scene::SaveLoad.new(g, state, :save)
30.times { g.main_loop }
tap(g, RGSS::Input::DOWN, 5)
tap(g, RGSS::Input::C, 40)
puts "save scene ok: #{g.instance_variable_get(:@scenes).last.class} exists=#{g.save_exists?(2)}"
