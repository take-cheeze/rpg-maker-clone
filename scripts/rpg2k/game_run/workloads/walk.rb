# Headless map walk: New Game, walk in a square for 600 frames, press C periodically to trigger events and messages.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
g = RPG2k.new(['TestPlay'])
g.start_new_game
dirs = [RGSS::Input::DOWN, RGSS::Input::RIGHT, RGSS::Input::UP, RGSS::Input::LEFT]
600.times do |i|
  if i % 40 == 0
    RGSS::Input.press(RGSS::Input::C)
  elsif i % 7 == 0
    RGSS::Input.press(dirs[(i / 7) % 4])
  end
  g.main_loop
end
puts "walk ok: #{g.instance_variable_get(:@scenes).last.class}"
