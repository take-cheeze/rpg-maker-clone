# Headless title screen: push the title scene and run frames on it, then press C to start a new game.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
g = RPG2k.new(['TestPlay'])
g.push RPG2k::Scene::Title.new(g)
30.times { g.main_loop }
puts "title frames ok: #{g.instance_variable_get(:@scenes).last.class}"
tap(g, RGSS::Input::C, 30)
puts "after C: #{g.instance_variable_get(:@scenes).last.class}"
