# Headless game over: New Game, push the game over scene and run its frames until it returns.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
g = RPG2k.new(['TestPlay'])
g.start_new_game
60.times { g.main_loop }
state = g.instance_variable_get(:@scenes).last.instance_variable_get(:@state)
g.push RPG2k::Scene::GameOver.new(g, state)
60.times { g.main_loop }
puts "game over ok: #{g.instance_variable_get(:@scenes).last.class}"
