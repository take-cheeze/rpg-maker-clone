# Headless item menu: New Game, open the item menu, move the cursor, use C and B, run frames between.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
g = RPG2k.new(['TestPlay'])
g.start_new_game
60.times { g.main_loop }
state = g.instance_variable_get(:@scenes).last.instance_variable_get(:@state)
g.push RPG2k::Scene::ItemMenu.new(g, state)
30.times { g.main_loop }
tap(g, RGSS::Input::DOWN, 5)
tap(g, RGSS::Input::C, 20)
tap(g, RGSS::Input::B, 20)
puts "item menu ok: #{g.instance_variable_get(:@scenes).last.class}"
