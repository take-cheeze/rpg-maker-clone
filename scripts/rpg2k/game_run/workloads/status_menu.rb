# Headless status menu: New Game, open the status screen, page to the next actor and back out.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
g = RPG2k.new(['TestPlay'])
g.start_new_game
60.times { g.main_loop }
state = g.instance_variable_get(:@scenes).last.instance_variable_get(:@state)
g.push RPG2k::Scene::StatusMenu.new(g, state, 0)
30.times { g.main_loop }
tap(g, RGSS::Input::RIGHT, 20)
tap(g, RGSS::Input::B, 20)
puts "status menu ok: #{g.instance_variable_get(:@scenes).last.class}"
