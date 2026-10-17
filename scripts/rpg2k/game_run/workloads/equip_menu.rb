# Headless equipment menu: New Game, open the equipment menu for the first actor, move, select and cancel.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
g = RPG2k.new(['TestPlay'])
g.start_new_game
60.times { g.main_loop }
state = g.instance_variable_get(:@scenes).last.instance_variable_get(:@state)
g.push RPG2k::Scene::EquipMenu.new(g, state, 0)
30.times { g.main_loop }
tap(g, RGSS::Input::DOWN, 5)
tap(g, RGSS::Input::C, 20)
tap(g, RGSS::Input::B, 20)
puts "equip menu ok: #{g.instance_variable_get(:@scenes).last.class}"
